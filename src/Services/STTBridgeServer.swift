import Foundation
import CommonCrypto
import AppKit

/// Minimal TCP server that serves both HTTP (STT page) and WebSocket (STT data).
///
/// - `GET /`  → returns an HTML page with Web Speech API + WebSocket client
/// - WebSocket upgrade → bidirectional JSON messaging for STT control/results
///
/// Replaces both the Chrome extension and Electron's sttBridge.ts.
@MainActor
final class STTBridgeServer: ObservableObject {
    static nonisolated let port: UInt16 = 17394

    @Published var isConnected = false
    @Published var subtitle = SubtitleState.empty
    @Published var isListening = false  // Whether STT is actively running

    /// Current STT language — used to skip redundant setLanguage calls
    private(set) var currentLang: String = "en-US"

    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var heartbeatTimer: Timer?
    private var readSource: DispatchSourceRead?
    private var listenSource: DispatchSourceRead?

    /// Pending STT start command — sent as soon as WS client connects
    private var pendingStartLang: String?

    /// Whether an STT page has been opened and is pending or active connection
    private var sttPageOpened = false

    // MARK: - Server lifecycle

    func start() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            appLog("[STT Bridge] Failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            appLog("[STT Bridge] Failed to bind: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        guard listen(serverSocket, 5) == 0 else {
            appLog("[STT Bridge] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        appLog("[STT Bridge] Server listening on port \(Self.port)")

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global())
        source.setEventHandler { [weak self] in
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(self?.serverSocket ?? -1, sockPtr, &clientLen)
                }
            }
            guard fd >= 0 else { return }
            Task { @MainActor in
                self?.handleNewClient(fd)
            }
        }
        source.resume()
        listenSource = source
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        readSource?.cancel()
        readSource = nil
        listenSource?.cancel()
        listenSource = nil
        if clientSocket >= 0 { close(clientSocket); clientSocket = -1 }
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
        isConnected = false
        isListening = false
        sttPageOpened = false
    }

    // MARK: - STT commands

    func startSTT(lang: String) {
        appLog("[STT Bridge] startSTT called, lang=\(lang), connected=\(isConnected)")
        isListening = true
        currentLang = lang

        if isConnected {
            send(["type": "start", "lang": lang])
        } else {
            // Save pending command and open browser
            pendingStartLang = lang
            openSTTPage()
        }
    }

    func stopSTT() {
        appLog("[STT Bridge] stopSTT called")
        isListening = false
        pendingStartLang = nil
        if isConnected {
            send(["type": "stop"])
        }
    }

    func setLanguage(_ lang: String) {
        guard lang != currentLang else {
            appLog("[STT Bridge] setLanguage skipped, already \(lang)")
            return
        }
        appLog("[STT Bridge] setLanguage: \(currentLang) -> \(lang)")
        currentLang = lang
        send(["type": "set-lang", "lang": lang])
    }

    /// Open the STT page in Chrome. Web Speech API only works in Chrome/Chromium.
    ///
    /// Priority: Chrome --app= mode (standalone window) → Chrome normal tab → alert
    /// Guarded by `sttPageOpened` to prevent duplicate windows.
    private func openSTTPage() {
        guard !sttPageOpened else {
            appLog("[STT Bridge] STT page already opened, skipping")
            return
        }
        sttPageOpened = true

        let urlString = "http://localhost:\(Self.port)"
        appLog("[STT Bridge] Opening STT page: \(urlString)")

        // Chrome binary paths to try for --app= mode
        let chromeBinaries = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]

        // Try --app= mode: launches as standalone window (like a PWA)
        for binary in chromeBinaries {
            if FileManager.default.fileExists(atPath: binary) {
                DispatchQueue.global().async {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: binary)
                    task.arguments = ["--app=\(urlString)"]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    do {
                        try task.run()
                    } catch {
                        appLog("[STT Bridge] Chrome --app= launch failed: \(error)")
                    }
                }
                appLog("[STT Bridge] Opened via Chrome --app= mode: \(binary)")
                return
            }
        }

        // Fallback: open as normal Chrome tab
        let chromeApps = ["Google Chrome", "Google Chrome Canary", "Chromium"]
        for app in chromeApps {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", app, urlString]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    appLog("[STT Bridge] Opened as Chrome tab via \(app)")
                    return
                }
            } catch {
                continue
            }
        }

        // No Chrome found
        appLog("[STT Bridge] Chrome not found")
        let alert = NSAlert()
        alert.messageText = "需要 Google Chrome"
        alert.informativeText = "语音识别（Web Speech API）仅支持 Chrome 浏览器，请先安装 Google Chrome。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    // MARK: - Connection handling

    private func handleNewClient(_ fd: Int32) {
        // Read the initial HTTP request on a background thread
        DispatchQueue.global().async { [weak self] in
            self?.handleHTTPRequest(fd)
        }
    }

    private nonisolated func handleHTTPRequest(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            close(fd)
            return
        }

        let request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""

        // Check if this is a WebSocket upgrade request
        let isWebSocketUpgrade = request.lowercased().contains("upgrade: websocket")

        if isWebSocketUpgrade {
            performWebSocketHandshake(fd, request: request)
        } else {
            serveHTTPPage(fd, request: request)
        }
    }

    // MARK: - HTTP page serving

    private nonisolated func serveHTTPPage(_ fd: Int32, request: String) {
        let html = Self.sttPageHTML
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        Cache-Control: no-cache\r
        \r\n
        """
        let response = headers + html
        let bytes = Array(response.utf8)
        _ = write(fd, bytes, bytes.count)
        close(fd)
    }

    // MARK: - WebSocket handshake

    private nonisolated func performWebSocketHandshake(_ fd: Int32, request: String) {
        guard let keyLine = request.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }) else {
            appLog("[STT Bridge] Missing Sec-WebSocket-Key")
            close(fd)
            return
        }

        let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let acceptKey = computeAcceptKey(key)

        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        let responseBytes = Array(response.utf8)
        _ = write(fd, responseBytes, responseBytes.count)

        Task { @MainActor in
            // Close previous WS client if any
            if self.clientSocket >= 0 {
                self.readSource?.cancel()
                self.readSource = nil
                close(self.clientSocket)
            }
            self.clientSocket = fd
            self.isConnected = true
            self.frameBuffer.removeAll()
            appLog("[STT Bridge] WebSocket client connected")

            // Start heartbeat
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.send(["type": "ping"])
                }
            }

            // Start reading frames
            self.startReading(fd)

            // Send pending start command if any
            if let lang = self.pendingStartLang {
                self.pendingStartLang = nil
                // Small delay to let the page initialize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.send(["type": "start", "lang": lang])
                }
            }
        }
    }

    private func startReading(_ fd: Int32) {
        readSource?.cancel()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                Task { @MainActor in
                    self?.clientDisconnected()
                }
                return
            }
            let data = Array(buffer[0..<n])
            Task { @MainActor in
                self?.processWebSocketData(data)
            }
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    private func clientDisconnected() {
        readSource?.cancel()
        readSource = nil
        if clientSocket >= 0 { close(clientSocket); clientSocket = -1 }
        isConnected = false
        sttPageOpened = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        appLog("[STT Bridge] WebSocket client disconnected")
    }

    // MARK: - WebSocket frame parsing

    private var frameBuffer = [UInt8]()

    private func processWebSocketData(_ bytes: [UInt8]) {
        frameBuffer.append(contentsOf: bytes)

        while frameBuffer.count >= 2 {
            let byte0 = frameBuffer[0]
            let byte1 = frameBuffer[1]
            let opcode = byte0 & 0x0F
            let masked = (byte1 & 0x80) != 0
            var payloadLen = UInt64(byte1 & 0x7F)
            var offset = 2

            if payloadLen == 126 {
                guard frameBuffer.count >= 4 else { return }
                payloadLen = UInt64(frameBuffer[2]) << 8 | UInt64(frameBuffer[3])
                offset = 4
            } else if payloadLen == 127 {
                guard frameBuffer.count >= 10 else { return }
                payloadLen = 0
                for i in 0..<8 {
                    payloadLen = payloadLen << 8 | UInt64(frameBuffer[2 + i])
                }
                offset = 10
            }

            let maskSize = masked ? 4 : 0
            let totalNeeded = offset + maskSize + Int(payloadLen)
            guard frameBuffer.count >= totalNeeded else { return }

            var payload = Array(frameBuffer[(offset + maskSize) ..< totalNeeded])

            if masked {
                let mask = Array(frameBuffer[offset ..< (offset + 4)])
                for i in 0..<payload.count {
                    payload[i] ^= mask[i % 4]
                }
            }

            frameBuffer.removeFirst(totalNeeded)

            switch opcode {
            case 0x1: // Text
                if let text = String(bytes: payload, encoding: .utf8) {
                    handleTextMessage(text)
                }
            case 0x8: // Close
                clientDisconnected()
                return
            case 0x9: // Ping → Pong
                sendRawFrame(opcode: 0xA, payload: payload)
            case 0xA: // Pong
                break
            default:
                break
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            appLog("[STT Bridge] Invalid message: \(text.prefix(100))")
            return
        }

        switch type {
        case "bridge-ready":
            appLog("[STT Bridge] Browser STT page ready")

        case "result":
            let resultText = json["text"] as? String ?? ""
            let isFinal = json["isFinal"] as? Bool ?? false
            if isFinal {
                appLog("[STT Bridge] FINAL: \(resultText)")
            }
            subtitle = SubtitleState(text: resultText, isFinal: isFinal)

        case "stt-started":
            appLog("[STT Bridge] STT started in browser")

        case "stt-stopped":
            appLog("[STT Bridge] STT stopped in browser")

        case "stt-error":
            let error = json["error"] as? String ?? "unknown"
            appLog("[STT Bridge] STT error from browser: \(error)")

        default:
            break
        }
    }

    // MARK: - WebSocket frame sending

    private func send(_ dict: [String: Any]) {
        guard clientSocket >= 0,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            appLog("[STT Bridge] send failed: clientSocket=\(clientSocket)")
            return
        }
        appLog("[STT Bridge] sending: \(text.prefix(100))")
        let payload = Array(text.utf8)
        sendRawFrame(opcode: 0x1, payload: payload)
    }

    private func sendRawFrame(opcode: UInt8, payload: [UInt8]) {
        guard clientSocket >= 0 else { return }

        var frame = [UInt8]()
        frame.append(0x80 | opcode)

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }

        frame.append(contentsOf: payload)

        let fd = clientSocket
        DispatchQueue.global().async {
            _ = write(fd, frame, frame.count)
        }
    }

    // MARK: - Crypto

    private nonisolated func computeAcceptKey(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let data = Array(magic.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &digest)
        return Data(digest).base64EncodedString()
    }

    // MARK: - Embedded STT HTML page

    static nonisolated let sttPageHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Island Radio — STT</title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro", sans-serif;
        background: #1a1a1a; color: #e0e0e0;
        display: flex; flex-direction: column; align-items: center;
        justify-content: center; min-height: 100vh; padding: 20px;
      }
      .card {
        background: #2a2a2a; border-radius: 16px; padding: 32px;
        max-width: 480px; width: 100%; text-align: center;
        box-shadow: 0 8px 32px rgba(0,0,0,0.4);
      }
      h1 { font-size: 20px; font-weight: 600; margin-bottom: 8px; }
      .status {
        font-size: 14px; color: #888; margin-bottom: 20px;
      }
      .dot {
        display: inline-block; width: 8px; height: 8px;
        border-radius: 50%; margin-right: 6px; vertical-align: middle;
      }
      .dot.green { background: #4ade80; }
      .dot.red { background: #ef4444; }
      .dot.yellow { background: #facc15; }
      .subtitle-box {
        background: #1a1a1a; border-radius: 10px; padding: 16px;
        min-height: 60px; margin: 16px 0; font-size: 15px;
        line-height: 1.5; text-align: left; color: #ccc;
      }
      .subtitle-box .interim { color: #888; }
      .hint {
        font-size: 12px; color: #666; margin-top: 16px;
      }
    </style>
    </head>
    <body>
    <div class="card">
      <h1>Island Radio STT</h1>
      <div class="status" id="status">
        <span class="dot yellow" id="dot"></span>
        <span id="statusText">正在连接…</span>
      </div>
      <div class="subtitle-box" id="subtitleBox">等待语音识别…</div>
      <div class="hint">此页面为 Island Radio 提供语音识别服务，请保持打开。</div>
    </div>

    <script>
    (function() {
      const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
      if (!SpeechRecognition) {
        document.getElementById('statusText').textContent = '浏览器不支持 Speech API';
        document.getElementById('dot').className = 'dot red';
        return;
      }

      const statusText = document.getElementById('statusText');
      const dot = document.getElementById('dot');
      const subtitleBox = document.getElementById('subtitleBox');

      let ws = null;
      let recognition = null;
      let currentLang = 'en-US';
      let shouldRestart = false;
      let lastSentText = '';

      function setStatus(text, color) {
        statusText.textContent = text;
        dot.className = 'dot ' + color;
      }

      function connectWS() {
        ws = new WebSocket('ws://localhost:' + location.port);

        ws.onopen = function() {
          console.log('[STT Page] WebSocket connected');
          setStatus('已连接，等待指令', 'green');
          ws.send(JSON.stringify({ type: 'bridge-ready' }));
        };

        ws.onmessage = function(e) {
          let msg;
          try { msg = JSON.parse(e.data); } catch { return; }
          console.log('[STT Page] received:', msg.type);

          switch (msg.type) {
            case 'start':
              currentLang = msg.lang || 'en-US';
              startRecognition(currentLang);
              break;
            case 'stop':
              stopRecognition();
              break;
            case 'set-lang':
              var newLang = msg.lang || 'en-US';
              if (newLang === currentLang) break;
              currentLang = newLang;
              if (recognition) {
                recognition.lang = newLang;
                shouldRestart = true;
                recognition.stop();
              }
              break;
            case 'ping':
              ws.send(JSON.stringify({ type: 'pong' }));
              break;
          }
        };

        ws.onclose = function() {
          console.log('[STT Page] WebSocket closed, reconnecting in 2s');
          setStatus('连接断开，重连中…', 'yellow');
          stopRecognition();
          setTimeout(connectWS, 2000);
        };

        ws.onerror = function(err) {
          console.error('[STT Page] WebSocket error:', err);
        };
      }

      function startRecognition(lang) {
        stopRecognition();
        shouldRestart = true;
        lastSentText = '';

        recognition = new SpeechRecognition();
        recognition.continuous = true;
        recognition.interimResults = true;
        recognition.lang = lang;
        recognition.maxAlternatives = 1;

        recognition.onstart = function() {
          console.log('[STT Page] Recognition started, lang=' + currentLang);
          setStatus('正在识别 (' + currentLang + ')', 'green');
          subtitleBox.textContent = '';
          if (ws && ws.readyState === 1) {
            ws.send(JSON.stringify({ type: 'stt-started' }));
          }
        };

        recognition.onresult = function(event) {
          let interim = '';
          let final_ = '';
          for (let i = event.resultIndex; i < event.results.length; i++) {
            const transcript = event.results[i][0].transcript;
            if (event.results[i].isFinal) {
              final_ += transcript;
            } else {
              interim += transcript;
            }
          }

          if (final_) {
            subtitleBox.innerHTML = final_;
            sendResult(final_, true);
          } else if (interim) {
            subtitleBox.innerHTML = '<span class="interim">' + interim + '</span>';
            sendResult(interim, false);
          }
        };

        recognition.onerror = function(event) {
          console.error('[STT Page] Recognition error:', event.error);
          if (event.error === 'not-allowed') {
            setStatus('麦克风权限被拒绝', 'red');
            shouldRestart = false;
            if (ws && ws.readyState === 1) {
              ws.send(JSON.stringify({ type: 'stt-error', error: event.error }));
            }
          } else if (event.error === 'no-speech') {
            // Normal, will auto-restart via onend
          } else {
            if (ws && ws.readyState === 1) {
              ws.send(JSON.stringify({ type: 'stt-error', error: event.error }));
            }
          }
        };

        recognition.onend = function() {
          console.log('[STT Page] Recognition ended, shouldRestart=' + shouldRestart);
          if (shouldRestart) {
            // Auto-restart (Speech API stops after silence or network timeout)
            setTimeout(function() {
              if (shouldRestart && recognition) {
                try { recognition.start(); } catch(e) {
                  console.error('[STT Page] Restart failed:', e);
                }
              }
            }, 300);
          } else {
            setStatus('已停止', 'yellow');
          }
        };

        try {
          recognition.start();
        } catch(e) {
          console.error('[STT Page] Start failed:', e);
          setStatus('启动失败: ' + e.message, 'red');
        }
      }

      function stopRecognition() {
        shouldRestart = false;
        if (recognition) {
          try { recognition.stop(); } catch(e) {}
          recognition = null;
        }
        if (ws && ws.readyState === 1) {
          ws.send(JSON.stringify({ type: 'stt-stopped' }));
        }
      }

      function sendResult(text, isFinal) {
        if (text === lastSentText && !isFinal) return;
        lastSentText = text;
        if (ws && ws.readyState === 1) {
          ws.send(JSON.stringify({ type: 'result', text: text, isFinal: isFinal }));
        }
      }

      // Start
      connectWS();
    })();
    </script>
    </body>
    </html>
    """
}
