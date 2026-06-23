{
  description = "A flake for setting up Flax-10 project development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      eachSystem = nixpkgs.lib.genAttrs systems;

      commonScript = ''
        WORK_DIR="$(pwd)"
      '';

    in {

      packages = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };

          # Initialise and start a project-local PostgreSQL cluster.
          # Exports POSTGRES_* variables so Django connects to it.
          pgScript =
            # Some Linux environments expose UIDs that PostgreSQL cannot resolve
            # via NSS when launched from Nix. Provide an nss_wrapper mapping
            # only on Linux (evaluated at Nix build time so the Darwin store
            # path for nss_wrapper is never referenced on macOS).
            pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              UID_VALUE="$(id -u)"
              GID_VALUE="$(id -g)"
              mkdir -p "$WORK_DIR/.postgres"
              NSS_PASSWD_FILE="$WORK_DIR/.postgres/nss-passwd"
              NSS_GROUP_FILE="$WORK_DIR/.postgres/nss-group"
              printf 'flax10:x:%s:%s:Flax-10 User:%s:/usr/sbin/nologin\n' "$UID_VALUE" "$GID_VALUE" "$WORK_DIR" > "$NSS_PASSWD_FILE"
              printf 'flax10:x:%s:\n' "$GID_VALUE" > "$NSS_GROUP_FILE"
              export NSS_WRAPPER_PASSWD="$NSS_PASSWD_FILE"
              export NSS_WRAPPER_GROUP="$NSS_GROUP_FILE"
              export LD_PRELOAD="${pkgs.nss_wrapper}/lib/libnss_wrapper.so:''${LD_PRELOAD:-}"
              export USER="flax10"
              export LOGNAME="flax10"
            ''
            + ''

            PGDATA_DIR="$WORK_DIR/.postgres/data"
            PGPORT_FILE="$WORK_DIR/.postgres/port"
            PGSOCKET_DIR="''${TMPDIR:-/tmp}/flax10-pg-$(id -u)"
            mkdir -p "$PGSOCKET_DIR"

            pick_pg_port() {
              python - <<'PY'
import socket

for port in range(5433, 5533):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            continue
        print(port)
        break
else:
    raise SystemExit("No free PostgreSQL port found in 5433-5532")
PY
            }

            set_pg_conf() {
              key="$1"
              value="$2"
              file="$PGDATA_DIR/postgresql.conf"
              tmp="$PGDATA_DIR/postgresql.conf.tmp"
              grep -Ev "^[[:space:]]*''${key}[[:space:]]*=" "''${file}" > "''${tmp}"
              echo "''${key} = ''${value}" >> "''${tmp}"
              mv "$tmp" "$file"
            }

            if [ ! -f "$PGDATA_DIR/PG_VERSION" ]; then
              echo "Initialising local PostgreSQL cluster..."
              mkdir -p "$PGDATA_DIR"
              initdb -D "$PGDATA_DIR" --no-locale --encoding=UTF8 --auth=trust
            fi

            PGPORT="$(cat "$PGPORT_FILE" 2>/dev/null || true)"
            if [ -n "$PGPORT" ] && ! [[ "$PGPORT" =~ ^[0-9]+$ ]]; then
              PGPORT=""
            fi

            if [ -n "$PGPORT" ] && ! pg_ctl -D "$PGDATA_DIR" status > /dev/null 2>&1; then
              if ! python - "$PGPORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        raise SystemExit(1)
raise SystemExit(0)
PY
              then
                PGPORT=""
              fi
            fi

            if [ -z "$PGPORT" ]; then
              PGPORT="$(pick_pg_port)"
              printf '%s\n' "$PGPORT" > "$PGPORT_FILE"
            fi

            set_pg_conf "listen_addresses" "'127.0.0.1'"
            set_pg_conf "port" "$PGPORT"
            set_pg_conf "unix_socket_directories" "'$PGSOCKET_DIR'"

            if ! pg_ctl -D "$PGDATA_DIR" status > /dev/null 2>&1; then
              echo "Starting local PostgreSQL..."
              pg_ctl -D "$PGDATA_DIR" -l "$PGDATA_DIR/logfile" start
              until pg_isready -h 127.0.0.1 -p "$PGPORT" > /dev/null 2>&1; do
                sleep 0.2
              done
            fi

            CURRENT_USER="$(id -un)"
            createdb -h 127.0.0.1 -p "$PGPORT" -U "$CURRENT_USER" flax10 2>/dev/null || true

            export POSTGRES_HOST="127.0.0.1"
            export POSTGRES_PORT="$PGPORT"
            export POSTGRES_USER="$CURRENT_USER"
            export POSTGRES_PASSWORD=""
            export POSTGRES_DB="flax10"
          '';

          # On Linux, make shared libraries visible to pip-installed C-extension
          # wheels (Pillow, psycopg-binary, etc.) that use manylinux bundles.
          ldLibScript = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [
              stdenv.cc.cc.lib
              zlib
              libpng
              libjpeg
              openssl
            ])}:''${LD_LIBRARY_PATH:-}"
          '';

        in {

          # ─── nix run .#init ───────────────────────────────────────────────
          # Installs all dependencies and seeds the database.
          init = pkgs.writeShellApplication {
            name = "init";
            runtimeInputs = with pkgs; [
              python312
              python312Packages.pip
              python312Packages.virtualenv
              nodejs_20
              git
              postgresql
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.nss_wrapper ];
            text = ''
              ${commonScript}
              ${ldLibScript}
              VENV_DIR="$WORK_DIR/flax-10-project-files/venv"
              FRONTEND_DIR="$WORK_DIR/flax-10-project-files/frontend"
              BACKEND_DIR="$WORK_DIR/flax-10-project-files/backend"

              echo ""
              echo "Entering Flax-10 wonderland..."
              echo ""

              # ── PostgreSQL setup ────────────────────────────────────────
              ${pgScript}

              # ── Python virtual environment ──────────────────────────────
              if [ ! -d "$VENV_DIR" ]; then
                echo "Creating virtual environment..."
                virtualenv "$VENV_DIR"
              fi

              # shellcheck disable=SC1091
              source "$VENV_DIR/bin/activate"
              echo "Installing Python dependencies..."
              pip install -r "$WORK_DIR/requirements.txt" --quiet

              # ── Frontend dependencies ───────────────────────────────────
              echo "Installing frontend dependencies..."
              cd "$FRONTEND_DIR"
              npm ci --silent

              # ── Database setup and seeding ──────────────────────────────
              echo "Running database migrations..."
              cd "$BACKEND_DIR"
              if python manage.py shell -c '
from django.db import connection

with connection.cursor() as cursor:
    cursor.execute(
        """
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = %s AND column_name = %s
        """,
        ["studyFlax_society", "location"],
    )
    print("present" if cursor.fetchone() else "missing")
' | grep -qx "present" && ! python manage.py showmigrations studyFlax | grep -Fq "[X] 0022_society_location"; then
                echo "Society location column already exists; faking studyFlax.0022_society_location..."
                python manage.py migrate studyFlax 0022_society_location --fake --noinput
              fi
              python manage.py migrate --noinput

              echo "Seeding database..."
              python manage.py seed

              echo ""
              echo "Init complete."
              echo ""
              echo "Next steps:"
              echo "  nix run .#run    - Start the development servers"
              echo "  nix run .#tests  - Run all tests and generate coverage"
            '';
          };

          # ─── nix run .#run ────────────────────────────────────────────────
          # Starts the backend and frontend development servers.
          run = pkgs.writeShellApplication {
            name = "run";
            runtimeInputs = with pkgs; [
              python312
              nodejs_20
              postgresql
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.nss_wrapper ];
            text = ''
              ${commonScript}
              ${ldLibScript}
              VENV_DIR="$WORK_DIR/flax-10-project-files/venv"
              FRONTEND_DIR="$WORK_DIR/flax-10-project-files/frontend"
              BACKEND_DIR="$WORK_DIR/flax-10-project-files/backend"

              # ── PostgreSQL setup ────────────────────────────────────────
              ${pgScript}

              # shellcheck disable=SC1091
              source "$VENV_DIR/bin/activate"

              pick_port() {
                python - "$1" <<'PY'
import socket
import sys

start = int(sys.argv[1])
for port in range(start, start + 100):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            continue
        print(port)
        break
else:
    raise SystemExit(f"No free port found starting at {start}")
PY
              }

              BACKEND_PORT="$(pick_port 8000)"
              FRONTEND_PORT="$(pick_port 5173)"

              cleanup() {
                [ -n "$BACKEND_PID" ] && kill "$BACKEND_PID" 2>/dev/null || true
                [ -n "$FRONTEND_PID" ] && kill "$FRONTEND_PID" 2>/dev/null || true
              }
              trap cleanup EXIT INT TERM

              echo ""
              echo "Starting Flax-10 development servers..."
              echo ""

              cd "$BACKEND_DIR"
              python manage.py runserver "127.0.0.1:$BACKEND_PORT" &
              BACKEND_PID=$!

              cd "$FRONTEND_DIR"
              npm run dev -- --host 127.0.0.1 --port "$FRONTEND_PORT" &
              FRONTEND_PID=$!

              echo "Backend:  http://127.0.0.1:$BACKEND_PORT"
              echo "Frontend: http://127.0.0.1:$FRONTEND_PORT"
              echo ""
              echo "Press Ctrl+C to stop both servers."

              wait $BACKEND_PID $FRONTEND_PID
            '';
          };

          # ─── nix run .#tests ──────────────────────────────────────────────
          # Runs all automated tests and generates coverage reports.
          # Reports are written to ./coverage/backend/ and ./coverage/frontend/
          tests = pkgs.writeShellApplication {
            name = "tests";
            runtimeInputs = with pkgs; [
              python312
              nodejs_20
              postgresql
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.nss_wrapper pkgs.xdg-utils ];
            text = ''
              ${commonScript}
              ${ldLibScript}
              VENV_DIR="$WORK_DIR/flax-10-project-files/venv"
              FRONTEND_DIR="$WORK_DIR/flax-10-project-files/frontend"
              BACKEND_DIR="$WORK_DIR/flax-10-project-files/backend"

              # ── PostgreSQL setup ────────────────────────────────────────
              ${pgScript}

              # shellcheck disable=SC1091
              source "$VENV_DIR/bin/activate"

              mkdir -p "$WORK_DIR/coverage/backend" "$WORK_DIR/coverage/frontend"

              # ── Backend tests ───────────────────────────────────────────
              echo ""
              echo "Running backend tests..."
              cd "$BACKEND_DIR"
              python -m coverage erase
              python -m coverage run --source=studyFlax manage.py test --verbosity=1
              python -m coverage report -m
              python -m coverage html --directory="$WORK_DIR/coverage/backend/html"
              python -m coverage xml -o "$WORK_DIR/coverage/backend/coverage.xml"

              # ── Frontend tests ──────────────────────────────────────────
              echo ""
              echo "Running frontend tests..."
              cd "$FRONTEND_DIR"
              npm run coverage
              cp -r coverage/. "$WORK_DIR/coverage/frontend/" 2>/dev/null || true

              echo ""
              echo "Coverage reports written to:"
              echo "  ./coverage/backend/html/index.html"
              echo "  ./coverage/backend/coverage.xml"
              echo "  ./coverage/frontend/"

              open_report() {
                target="$1"
                if command -v open >/dev/null 2>&1; then
                  open "$target" >/dev/null 2>&1 || true
                elif command -v xdg-open >/dev/null 2>&1; then
                  xdg-open "$target" >/dev/null 2>&1 || true
                fi
              }

              echo ""
              echo "Attempting to open coverage reports..."
              open_report "$WORK_DIR/coverage/backend/html/index.html"
              open_report "$WORK_DIR/coverage/frontend/index.html"
            '';
          };

          # ─── nix run .#unseed ─────────────────────────────────────────────
          # Removes all seed data and allows immediate re-seeding.
          unseed = pkgs.writeShellApplication {
            name = "unseed";
            runtimeInputs = with pkgs; [
              python312
              postgresql
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.nss_wrapper ];
            text = ''
              ${commonScript}
              ${ldLibScript}
              VENV_DIR="$WORK_DIR/flax-10-project-files/venv"
              BACKEND_DIR="$WORK_DIR/flax-10-project-files/backend"
              ${pgScript}
              # shellcheck disable=SC1091
              source "$VENV_DIR/bin/activate"
              cd "$BACKEND_DIR"
              printf 'yes\n' | python manage.py unseed
              echo "Seed data removed. Run 'nix run .#init' to re-seed."
            '';
          };

          # ─── nix run .#seed ───────────────────────────────────────────────
          # Seeds the database without full initialisation.
          seed = pkgs.writeShellApplication {
            name = "seed";
            runtimeInputs = with pkgs; [
              python312
              postgresql
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.nss_wrapper ];
            text = ''
              ${commonScript}
              ${ldLibScript}
              VENV_DIR="$WORK_DIR/flax-10-project-files/venv"
              BACKEND_DIR="$WORK_DIR/flax-10-project-files/backend"
              ${pgScript}
              # shellcheck disable=SC1091
              source "$VENV_DIR/bin/activate"
              cd "$BACKEND_DIR"
              python manage.py seed
              echo "Database seeded."
            '';
          };

        }
      );

      # ─── nix develop ───────────────────────────────────────────────────────
      devShells = eachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python312
              python312Packages.pip
              python312Packages.virtualenv
              nodejs_20
              git
              postgresql
            ];
            shellHook = ''
              echo ""
              echo "Flax-10 development environment"
              echo ""
              echo "Available entrypoints:"
              echo "  nix run .#init    - Install dependencies and seed the database"
              echo "  nix run .#run     - Start the development servers"
              echo "  nix run .#tests   - Run all tests and generate coverage reports"
              echo "  nix run .#seed    - Seed the database with sample data"
              echo "  nix run .#unseed  - Remove all seed data"
              echo ""
            '';
          };
        }
      );

    };
}