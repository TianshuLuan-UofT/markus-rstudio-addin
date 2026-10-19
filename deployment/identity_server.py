import os
import pwd
import socket
import struct
import time
import jwt
import stat

SOCKET_PATH = os.environ.get(
    "RMARKUS_IDENTITY_SOCKET",
    "/run/rmarkus/identity.sock"
)

SECRET = os.environ["RMARKUS_AUTH_SECRET"]

if os.path.lexists(SOCKET_PATH):
    socket_info = os.lstat(SOCKET_PATH)

    if not stat.S_ISSOCK(socket_info.st_mode):
        raise RuntimeError(
            f"Refusing to remove a non-socket file: {SOCKET_PATH}"
        )

    if socket_info.st_uid != os.geteuid():
        raise PermissionError(
            f"Socket is not owned by this service: {SOCKET_PATH}"
        )

    raise RuntimeError(
        f"Socket already exists: {SOCKET_PATH}. "
        "Check whether another identity service is running."
    )

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCKET_PATH)

# Allow authorized RStudio users to connect without
# granting access to the identity service's signing secret.
import grp

client_gid = grp.getgrnam("rmarkus-clients").gr_gid
os.chown(SOCKET_PATH, -1, client_gid)
os.chmod(SOCKET_PATH, 0o660)

server.listen(128)

print(f"Listening on {SOCKET_PATH}", flush=True)

while True:
    conn, _ = server.accept()

    with conn:
        try:
            creds = conn.getsockopt(
                socket.SOL_SOCKET,
                socket.SO_PEERCRED,
                struct.calcsize("3i")
            )

            pid, uid, gid = struct.unpack("3i", creds)
            username = pwd.getpwuid(uid).pw_name

            now = int(time.time())

            token = jwt.encode(
                {
                    "user_name": username,
                    "iss": "rmarkus-identity",
                    "aud": "markus-rstudio",
                    "iat": now,
                    "nbf": now,
                    "exp": now + 60
                },
                SECRET,
                algorithm="HS256"
            )

            print(
                f"authenticated: pid={pid} uid={uid} user={username}",
                flush=True
            )

            body = token.encode()

            response = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode() + body

            conn.sendall(response)

        except Exception as e:
            print(
                f"Identity request failed: {type(e).__name__}: {e}",
                flush=True
            )
