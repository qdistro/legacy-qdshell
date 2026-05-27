// ctrl-server.cpp — see ctrl-server.h for shape + rationale.
//
// SPDX-License-Identifier: GPL-3.0-or-later

#include "ctrl-server.h"
#include "qdwin-binding.h"

#include <QDebug>
#include <QFile>
#include <QLocalSocket>
#include <QTimer>

#include <cstdlib>
#include <unistd.h>
#include <sys/stat.h>

namespace {

// Per-client timeout (ms) — if a connected client sends no data
// within this window we close it. Prevents a misbehaving local
// client from accumulating idle sockets.
constexpr int kClientTimeoutMs = 2000;

QString socketPath() {
    const char *xdg = std::getenv("XDG_RUNTIME_DIR");
    if (xdg && xdg[0])
        return QStringLiteral("%1/qdshell.sock").arg(QString::fromUtf8(xdg));
    return QStringLiteral("/run/user/%1/qdshell.sock").arg(getuid());
}

} // namespace

CtrlServer::CtrlServer(QdwinBinding &binding, QObject *parent)
    : QObject(parent)
    , binding_(binding)
{
    const QString path = socketPath();

    // Remove stale socket from a previous crash / unclean shutdown.
    QFile::remove(path);

    server_.setSocketOptions(QLocalServer::UserAccessOption);

    if (!server_.listen(path)) {
        qWarning().noquote()
            << "ctrl-server: failed to listen on" << path
            << "—" << server_.errorString();
        return;
    }

    // Record that *we* own this path so the destructor only removes
    // a socket it actually created — a second qdshell instance won't
    // accidentally unlink an active server's socket on exit.
    listenedPath_ = path;
    listening_ = true;

    // Tighten permissions to 0600 (belt-and-braces; UserAccessOption
    // already restricts on most platforms).
    ::chmod(path.toUtf8().constData(), 0600);

    connect(&server_, &QLocalServer::newConnection,
            this, &CtrlServer::onNewConnection);

    qInfo().noquote() << "ctrl-server: listening on" << path;
}

CtrlServer::~CtrlServer() {
    server_.close();
    if (listening_) {
        QFile::remove(listenedPath_);
        listening_ = false;
    }
}

void CtrlServer::onNewConnection() {
    while (QLocalSocket *sock = server_.nextPendingConnection()) {
        connect(sock, &QLocalSocket::disconnected,
                sock, &QLocalSocket::deleteLater);

        if (sock->bytesAvailable() > 0) {
            // Data already buffered (the common case for socat / echo).
            handleConnection(sock);
        } else {
            // Fully async: wait for readyRead instead of blocking
            // the Qt event loop with waitForReadyRead.
            connect(sock, &QLocalSocket::readyRead,
                    this, &CtrlServer::onReadyRead);

            // Arm a per-client timeout so a misbehaving connector
            // that never sends data gets cleaned up.
            auto *timer = new QTimer(sock);  // parented to sock
            timer->setSingleShot(true);
            connect(timer, &QTimer::timeout,
                    this, &CtrlServer::onClientTimeout);
            timer->start(kClientTimeoutMs);
        }
    }
}

void CtrlServer::onReadyRead() {
    auto *sock = qobject_cast<QLocalSocket *>(sender());
    if (!sock) return;

    // Disconnect so we handle exactly one command per connection.
    disconnect(sock, &QLocalSocket::readyRead,
               this, &CtrlServer::onReadyRead);

    handleConnection(sock);
}

void CtrlServer::onClientTimeout() {
    auto *timer = qobject_cast<QTimer *>(sender());
    if (!timer) return;

    // The timer is parented to the socket.
    auto *sock = qobject_cast<QLocalSocket *>(timer->parent());
    if (!sock) return;

    qWarning().noquote() << "ctrl-server: client timed out, closing";
    sock->disconnectFromServer();
    sock->deleteLater();
}

void CtrlServer::handleConnection(QLocalSocket *sock) {
    // Protocol: one line per connection, max 1 KiB.
    QByteArray data = sock->readLine(1024);

    // Reject overlong / truncated lines: a well-formed command must
    // end with '\n'. readLine(1024) returns at most 1024 bytes; if
    // the last byte is not '\n', the client either sent a line longer
    // than the protocol allows or closed without a newline terminator.
    if (!data.isEmpty() && !data.endsWith('\n')) {
        sock->write(QByteArrayLiteral("error: command too long or unterminated\n"));
        sock->flush();
        sock->disconnectFromServer();
        return;
    }

    QString line = QString::fromUtf8(data).trimmed();

    QString reply = handleCommand(line);

    sock->write((reply + QStringLiteral("\n")).toUtf8());
    sock->flush();
    sock->disconnectFromServer();
}

QString CtrlServer::handleCommand(const QString &line) {
    if (line.isEmpty())
        return QStringLiteral("error: empty command");

    const int sp = line.indexOf(QLatin1Char(' '));
    const QString cmd = (sp >= 0) ? line.left(sp) : line;

    if (cmd == QLatin1String("last-overlay-keys")) {
        return QStringLiteral("count=%1 last-role=%2 last-sym=%3 last-utf8=\"%4\"")
            .arg(binding_.overlayKeyCount())
            .arg(binding_.lastOverlayRole())
            .arg(binding_.lastOverlaySym())
            .arg(binding_.lastOverlayUtf8());
    }

    if (cmd == QLatin1String("status")) {
        return QStringLiteral("ok");
    }

    return QStringLiteral("error: unknown command '%1'").arg(cmd);
}
