# MarkUs RStudio Addin

Submit an R file from RStudio directly to a [MarkUs](https://github.com/MarkUsProject/Markus) assignment. The addin presents a course/assignment selector and authenticates the RStudio user through a local identity broker—students do **not** enter a MarkUs password or API key.

This repository contains the standalone **`MarkUsRStudioAddin`** R package and a Python identity broker. The MarkUs server-side RStudio endpoints are implemented separately in the MarkUs application; installing this package alone does not add those endpoints.

## How it works

```text
RStudio user
   │
   ├─ Addins → Submit to MarkUs
   │
   └─ R package ── Unix domain socket ──► Identity broker
          │                                  │
          │                       SO_PEERCRED identifies Unix user
          │                                  │
          │◄────────── short-lived signed JWT ┘
          │
          └─ HTTPS/HTTP ──► MarkUs RStudio API
                              │
                         verify JWT
                              │
                      authenticate user
                              │
                     courses / assignments
                              │
                         file submission
```

The broker obtains the caller's operating-system identity using Linux `SO_PEERCRED` and issues a short-lived HS256 JWT. MarkUs verifies the signature, issuer, audience, and token validity before establishing a submission session. **The signing secret must never be accessible to students or stored in the R package.**

## Requirements

### RStudio host

- Linux host (the identity broker relies on Linux Unix-socket peer credentials).
- R and RStudio Server.
- R packages: `shiny`, `httr2`, `curl`, and `rstudioapi`.
- Python 3 with the `PyJWT` module available to the Python interpreter used by the broker.
- `systemd` for the example deployment below.
- A local Unix account for each student, with a username that maps to the corresponding MarkUs account.

### MarkUs server

The MarkUs instance must have the companion RStudio submission endpoints installed and configured:

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `/rstudio/authenticate` | Exchange broker identity JWT for a MarkUs session |
| GET | `/rstudio/courses` | List accessible courses |
| GET | `/rstudio/assignments` | List accessible assignments |
| POST | `/rstudio/submit` | Submit the selected file |

The exact URL prefix depends on the MarkUs deployment. In the tested development environment the application base URL was `http://localhost:3000/csc108`. The addin does not provide or install the Rails controller/routes.

## 1. Install the R package

On the RStudio host, clone this repository and install the package:

```bash
git clone https://github.com/MarkUsProject/markus-rstudio-addin.git
cd markus-rstudio-addin
Rscript -e 'install.packages(c("shiny", "httr2", "curl", "rstudioapi"), repos="https://cloud.r-project.org")'
R CMD INSTALL .
```

If the integration is not yet merged into `main`, check out the relevant branch before running `R CMD INSTALL .`.

To verify installation:

```bash
Rscript -e 'library(MarkUsRStudioAddin); stopifnot(exists("markus_submit_addin"))'
```

For a shared RStudio Server, an administrator should install the package in a library accessible to all intended users.

## 2. Configure the MarkUs backend

Deploy the companion RStudio Rails routes/controller in MarkUs. Configure **the same strong, randomly generated signing secret** for both the MarkUs application and the identity broker using `RMARKUS_AUTH_SECRET`.

The authentication endpoint must validate the JWT using:

- Algorithm: `HS256`
- Issuer (`iss`): `rmarkus-identity`
- Audience (`aud`): `markus-rstudio`
- Expiration (`exp`) and not-before (`nbf`) claims
- Identity claim: `user_name` (the Unix username)

The broker currently issues identity tokens valid for approximately **60 seconds**; the MarkUs implementation establishes a separate, short-lived authenticated session (15 minutes in the tested implementation).

**Security:** Use HTTPS for MarkUs endpoints outside a local development environment. Do not commit secrets, print JWTs in logs, or allow users to choose an arbitrary `user_name` in place of the broker-derived identity. Account mapping and authorization must be enforced by MarkUs.

## 3. Deploy the identity broker (administrator)

The following example matches the tested Ubuntu/systemd deployment. Adapt usernames and paths to your institution's environment.

### Create service account and access group

```bash
sudo groupadd --system rmarkus-clients
sudo useradd --system --no-create-home --shell /usr/sbin/nologin rmarkus
```

If either already exists, do not recreate it. Add each authorized RStudio Unix user to the client group, for example:

```bash
sudo usermod -aG rmarkus-clients STUDENT_UNIX_USERNAME
```

Users must start a **new login/RStudio session** for group membership changes to take effect. For large deployments, provision membership through your existing account-management process.

### Install broker code and Python dependency

Install `PyJWT` for `/usr/bin/python3` using your distribution's supported package mechanism (for example, `sudo apt-get install python3-jwt` on Ubuntu if available). Check with:

```bash
/usr/bin/python3 -c 'import jwt; print(jwt.__version__)'
```

Copy the broker to a root-managed directory:

```bash
sudo install -d -o root -g root -m 0755 /opt/rmarkus
sudo install -o root -g root -m 0644 deployment/identity_server.py /opt/rmarkus/identity_server.py
```

### Configure the shared signing secret

Create `/etc/rmarkus/identity.env` containing:

```dotenv
RMARKUS_AUTH_SECRET=REPLACE_WITH_THE_SAME_STRONG_SECRET_CONFIGURED_IN_MARKUS
```

Protect it:

```bash
sudo chown root:root /etc/rmarkus/identity.env
sudo chmod 0600 /etc/rmarkus/identity.env
```

Create `/etc/rmarkus` as root-owned and mode `0700` before writing the file. The value shown above is a **placeholder**, not a usable deployment secret. Never add this file to Git.

### Configure systemd

Create `/etc/systemd/system/rmarkus-identity.service`:

```ini
[Unit]
Description=RMarkUs Identity Broker
After=local-fs.target

[Service]
Type=simple
User=rmarkus
Group=rmarkus-clients
WorkingDirectory=/opt/rmarkus
Environment=RMARKUS_IDENTITY_SOCKET=/run/rmarkus/identity.sock
EnvironmentFile=/etc/rmarkus/identity.env
ExecStart=/usr/bin/python3 /opt/rmarkus/identity_server.py
Restart=on-failure
RestartSec=3

RuntimeDirectory=rmarkus
RuntimeDirectoryMode=0710

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Start and enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rmarkus-identity
systemctl is-active rmarkus-identity
systemctl is-enabled rmarkus-identity
```

Expected output is `active` and `enabled`. The broker creates `/run/rmarkus/identity.sock` with permissions allowing the `rmarkus-clients` group to connect. Check ownership and permissions:

```bash
sudo ls -ld /run/rmarkus
sudo ls -l /run/rmarkus/identity.sock
```

Expected directory ownership: `rmarkus:rmarkus-clients` with mode `0710`; expected socket ownership: `rmarkus:rmarkus-clients` with mode `0660`.

**Do not expose the identity broker over TCP or make the socket world-writable.**

## 4. Configure RStudio

In the RStudio Console, set the MarkUs base URL and local broker socket path:

```r
options(
  rmarkus.base_url = "https://YOUR-MARKUS-HOST/YOUR-COURSE-PATH",
  rmarkus.identity_socket = "/run/rmarkus/identity.sock"
)
```

For the tested local development environment:

```r
options(
  rmarkus.base_url = "http://localhost:3000/csc108",
  rmarkus.identity_socket = "/run/rmarkus/identity.sock"
)
```

These `options()` are session-specific. Administrators can configure appropriate defaults through a managed R startup file (for example, site-level `Rprofile.site`) rather than asking every student to enter them manually. **Do not put the signing secret in any R startup file.**

The addin is registered in `inst/rstudio/addins.dcf` as **Submit to MarkUs** and invokes `markus_submit_addin()`.

## 5. Submit a file (student)

1. Sign in to RStudio Server with your assigned Unix account.
2. Open the `.R` file you want to submit and save your changes.
3. Choose **Addins → Submit to MarkUs**.
4. Select the MarkUs course and assignment shown in the dialog.
5. Submit the file and check the result in MarkUs.

No separate MarkUs username/password or API token is requested by the addin. Available courses and assignments depend on the authenticated MarkUs user and backend authorization.

## 6. Verify the installation

As an authorized RStudio user, check the broker's availability **without displaying its token**:

```bash
curl -sS --unix-socket /run/rmarkus/identity.sock \
  http://localhost/ -o /dev/null -w 'HTTP status: %{http_code}\n'
```

Expected: `HTTP status: 200`.

From RStudio, after setting the options and loading the package, perform an end-to-end test by submitting a harmless test `.R` file to a test assignment. Verify the submitted file appears in MarkUs.

For package maintainers:

```bash
R CMD build .
R CMD check --no-manual MarkUsRStudioAddin_*.tar.gz
```

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Addin missing from RStudio | Package installed in the active R library; restart RStudio; verify `inst/rstudio/addins.dcf` |
| Missing MarkUs URL | Set `options(rmarkus.base_url = "...")` before opening the addin |
| Cannot connect to identity socket | Broker active; socket path correct; directory group and socket permissions; RStudio session has refreshed group membership |
| Broker fails to start | `sudo systemctl status rmarkus-identity` and `sudo journalctl -u rmarkus-identity -n 50 --no-pager` |
| Authentication rejected | Matching signing secrets; correct `iss`/`aud`; server clocks; Unix username maps to a MarkUs user |
| Courses/assignments missing | MarkUs user enrollment, permissions, assignment availability, and backend routes |
| Submission fails | Saved active document, assignment selection, MarkUs response, and Rails logs |

## Deployment and security notes

This integration was validated on an Ubuntu 24.04 VM with R 4.3.3, RStudio Server, a systemd-managed identity broker, and a development MarkUs instance. The standalone R package installed successfully, passed `R CMD check` in the tested setup, and completed a real test submission.

Before production rollout, review secret rotation, HTTPS/TLS, multi-host deployments, username mapping, upload validation and limits, logging, service monitoring, and institutional authorization requirements. A shared HS256 secret is suitable for the documented single-environment integration but may warrant replacement with asymmetric signing or a centralized identity system at larger scale.

## License

MIT. See [LICENSE](LICENSE).
