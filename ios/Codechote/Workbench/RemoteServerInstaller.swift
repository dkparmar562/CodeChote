import Foundation

/// Shell script run on the Linux host. It installs the VS Code server on first use, starts it
/// detached on a random loopback port with a random connection token, and prints
/// `CODECHOTE_READY <port> <token>`. If a previously started server is still alive it is reused,
/// which is what makes reconnecting after iOS suspends the app seamless.
enum RemoteServerInstaller {
    /// `@ARCH@` is substituted on the host (x64 / arm64). Replace with your own fork's release
    /// asset once it is built; the stock build is used to validate the pipeline.
    static let defaultDownloadURL = "https://update.code.visualstudio.com/latest/server-@OS@-@ARCH@-web/stable"

    /// The server must be exactly the commit the bundled UI was built from: the two talk over a
    /// protocol whose shape changes between versions (a mismatch breaks extensions, not just the UI).
    /// `uiCommit` comes from the UI bundle; without it the stock "latest" server is used.
    static func downloadURL(forCommit commit: String?) -> String {
        guard let commit, !commit.isEmpty else { return defaultDownloadURL }
        return "https://update.code.visualstudio.com/commit:\(commit)/server-@OS@-@ARCH@-web/stable"
    }

    static func script(downloadURL: String = defaultDownloadURL, commit: String? = nil) -> String {
        let body = #"""
        set -u
        D="${CODECHOTE_HOME:-$HOME/.codechote-server}"
        mkdir -p "$D" && cd "$D" || { echo "CODECHOTE_ERR cannot create $D"; exit 1; }
        case "$(uname -s)" in
          Linux) OS=linux;;
          Darwin) OS=darwin;;
          *) echo "CODECHOTE_ERR unsupported host OS ($(uname -s))"; exit 1;;
        esac
        case "$(uname -m)" in
          x86_64) A=x64;;
          aarch64|arm64) A=arm64;;
          armv7l) A=armhf;;
          *) echo "CODECHOTE_ERR unsupported architecture $(uname -m)"; exit 1;;
        esac

        PIN="@PIN@"
        if [ -f server.env ]; then
          . ./server.env
          if [ -n "${COMMIT:-}" ] && { [ -z "$PIN" ] || [ "$COMMIT" = "$PIN" ]; } && [ -f "$D/product.json" ] && kill -0 "$PID" 2>/dev/null && (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
            echo "CODECHOTE_PRODUCT $(base64 < "$D/product.json" | tr -d '\n')"
            echo "CODECHOTE_READY $PORT $TOKEN $COMMIT $QUALITY"; exit 0
          fi
          [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
        fi

        SRV=""
        SDIR="$D/server${PIN:+-$PIN}"
        if [ -x "$SDIR/bin/code-server" ]; then
          SRV="$SDIR"
        elif [ -n "$PIN" ]; then
          : # pinned: never fall back to some other version
        else
          # Reuse a server already on the host (e.g. from VS Code Remote-SSH) if it ships the web UI.
          for c in "$HOME"/.vscode-server/cli/servers/*/server "$HOME"/.vscode-server/bin/*; do
            if [ -x "$c/bin/code-server" ] && [ -f "$c/out/vs/code/browser/workbench/workbench.html" ]; then SRV="$c"; fi
          done
          [ -n "$SRV" ] && echo "CODECHOTE_STATUS Using existing server"
        fi

        if [ -z "$SRV" ]; then
          URL="@URL@"
          URL="${URL//@OS@/$OS}"
          URL="${URL//@ARCH@/$A}"
          echo "CODECHOTE_STATUS Downloading server ($A)"
          rm -rf server.tmp server.tgz; mkdir server.tmp
          rm -f dl.err
          if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 20 "$URL" -o server.tgz 2>dl.err; RC=$?; TOOL=curl
          elif command -v wget >/dev/null 2>&1; then wget -O server.tgz "$URL" 2>dl.err; RC=$?; TOOL=wget
          else echo "CODECHOTE_ERR need curl or wget on the host"; exit 1; fi
          if [ "$RC" != 0 ]; then
            echo "CODECHOTE_ERR download failed: $TOOL exit $RC from $URL :: $(tail -c 400 dl.err | tr '\n\r' '  ')"
            exit 1
          fi
          echo "CODECHOTE_STATUS Unpacking"
          tar -xzf server.tgz -C server.tmp --strip-components=1 || { echo "CODECHOTE_ERR unpack failed"; exit 1; }
          rm -rf "$SDIR"; mv server.tmp "$SDIR"; rm -f server.tgz
          SRV="$SDIR"
        fi

        echo "CODECHOTE_STATUS Starting server"
        COMMIT=$(sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' "$SRV/product.json" | head -1)
        QUALITY=$(sed -n 's/.*"quality": *"\([a-z]*\)".*/\1/p' "$SRV/product.json" | head -1)
        : "${COMMIT:=none}" "${QUALITY:=none}"
        TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
        rm -f server.log server.env
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup "$SRV/bin/code-server" --host 127.0.0.1 --port 0 --connection-token "$TOKEN" --accept-server-license-terms --telemetry-level off >server.log 2>&1 </dev/null &
        else
          nohup "$SRV/bin/code-server" --host 127.0.0.1 --port 0 --connection-token "$TOKEN" --accept-server-license-terms --telemetry-level off >server.log 2>&1 </dev/null &
        fi
        PID=$!
        for i in $(seq 1 150); do
          PORT=$(sed -n 's/.*Web UI available at http:\/\/[^:]*:\([0-9][0-9]*\).*/\1/p' server.log | head -1)
          if [ -n "$PORT" ]; then
            printf 'PID=%s\nPORT=%s\nTOKEN=%s\nCOMMIT=%s\nQUALITY=%s\n' "$PID" "$PORT" "$TOKEN" "$COMMIT" "$QUALITY" > server.env
            cp "$SRV/product.json" "$D/product.json" 2>/dev/null
            echo "CODECHOTE_PRODUCT $(base64 < "$D/product.json" | tr -d '\n')"
            echo "CODECHOTE_READY $PORT $TOKEN $COMMIT $QUALITY"; exit 0
          fi
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.2
        done
        echo "CODECHOTE_ERR server failed to start: $(tail -n 5 server.log | tr '\n' ' ')"
        exit 1
        """#
        return body
            .replacingOccurrences(of: "@URL@", with: downloadURL)
            .replacingOccurrences(of: "@PIN@", with: commit ?? "")
    }

    /// Wrap the script so it runs under bash regardless of the user's login shell.
    static func command(commit: String? = nil) -> String {
        let b64 = Data(script(downloadURL: downloadURL(forCommit: commit), commit: commit).utf8).base64EncodedString()
        return "echo \(b64) | base64 -d | bash"
    }
}
