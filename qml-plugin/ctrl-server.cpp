// ctrl-server.cpp — see ctrl-server.h for shape + rationale.
//
// SPDX-License-Identifier: GPL-3.0-or-later

#include "ctrl-server.h"
#include "qdwin-binding.h"

#include <QDebug>
#include <QFile>
#include <QLocalSocket>

#include <cstdlib>
#include <unistd.h>
#include <sys/stat.h>

namespace {

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

    // Tighten permissions to 0600 (belt-and-braces; UserAccessOption
    // already restricts on most platforms).
    ::chmod(path.toUtf8().constData(), 0600);

    connect(&server_, &QLocalServer::newConnection,
            this, &CtrlServer::onNewConnection);

    qInfo().noquote() << "ctrl-server: listening on" << path;
}

CtrlServer::~CtrlServer() {
    server_.close();
    const QString path = socketPath();
    QFile::remove(path);
}

void CtrlServer::onNewConnection() {
    while (QLocalSocket *sock = server_.nextPendingConnection()) {
        connect(sock, &QLocalSocket::disconnected,
                sock, &QLocalSocket::deleteLater);

        // Give the client a brief window to send its command.
        // Typical callers (socat, echo | nc) write before we get here,
        // so waitForReadyRead returns immediately.
        if (sock->bytesAvailable() == 0)
            sock->waitForReadyRead(500);

        if (sock->bytesAvailable() > 0) {
            handleConnection(sock);
        } else {
            // Deferred — data hasn't arrived yet. Wire readyRead.
            connect(sock, &QLocalSocket::readyRead,
                    this, &CtrlServer::onReadyRead);
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

void CtrlServer::handleConnection(QLocalSocket *sock) {
    // Protocol: one line per connection, max 1 KiB.
    QByteArray data = sock->readLine(1024);
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
