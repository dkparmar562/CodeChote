import Observation
import WebKit

/// Native <-> workbench bridge: injects helpers into the page and lets the SwiftUI key bar
/// send keys (which iOS's soft keyboard lacks) to whatever element has focus.
@MainActor
@Observable
final class WebBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var ctrlActive = false
    var isReady = false
    let nav = NavModel()
    /// Called when the page asks for a new window (a folder to open in it).
    var openWindow: ((String) -> Void)?

    override init() {
        super.init()
        nav.pickReply = { [weak self] id, path in
            let converted = path.map { HostPath.toWorkbench($0, windows: self?.nav.isWindows ?? false) }
            let value = converted.map { Self.quote($0) } ?? "null"
            self?.js("window.__ccNav && window.__ccNav.pickResult(\(Self.quote(id)), \(value))")
        }
        nav.activateHandler = { [weak self] id in
            self?.js("window.__ccNav && window.__ccNav.activate(\(Self.quote(id)))")
        }
    }

    /// Helpers the key bar and the app use, plus the "workbench is ready" signal. In debug builds the page's
    /// console errors are forwarded to Xcode's console as well.
    static let script: String = core + debugLogging

    private static let core = #"""
    (function () {
      if (window.__cc) return;
      var codes = { Escape: 27, Tab: 9, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Enter: 13, Backspace: 8 };
      function make(type, key, ctrl) {
        var kc = codes[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
        var code = /^[a-z]$/i.test(key) ? 'Key' + key.toUpperCase() : key;
        var e = new KeyboardEvent(type, { key: key, code: code, ctrlKey: !!ctrl, bubbles: true, cancelable: true, composed: true });
        Object.defineProperty(e, 'keyCode', { get: function () { return kc; } });
        Object.defineProperty(e, 'which', { get: function () { return kc; } });
        return e;
      }
      window.__cc = {
        ctrl: false,
        key: function (key, ctrl) {
          var t = document.activeElement || document.body;
          t.dispatchEvent(make('keydown', key, ctrl));
          t.dispatchEvent(make('keyup', key, ctrl));
        },
        text: function (s) { document.execCommand('insertText', false, s); },
        blur: function () { if (document.activeElement) document.activeElement.blur(); }
      };
      var readyTimer = setInterval(function () {
        if (document.querySelector('.monaco-workbench .part')) {
          clearInterval(readyTimer);
          window.webkit.messageHandlers.cc.postMessage('ready');
        }
      }, 250);
      // Sticky Ctrl from the key bar: the next typed letter becomes Ctrl+letter.
      window.addEventListener('keydown', function (e) {
        if (!window.__cc.ctrl || !e.isTrusted || e.key.length !== 1 || e.metaKey || e.ctrlKey || e.altKey) return;
        e.preventDefault(); e.stopImmediatePropagation();
        window.__cc.ctrl = false;
        window.webkit.messageHandlers.cc.postMessage('ctrlCleared');
        window.__cc.key(e.key.toLowerCase(), true);
      }, true);
    })();
    """#

    #if DEBUG
    private static let debugLogging = #"""
    (function () {
      function send(kind, args) {
        try {
          window.webkit.messageHandlers.cc.postMessage('log:' + kind + ': ' + Array.prototype.map.call(args, function (a) {
            return a && a.stack ? (a.message ? a.message + ' :: ' : '') + a.stack.split('\n').slice(0, 3).join(' | ') : (typeof a === 'object' ? JSON.stringify(a) : String(a));
          }).join(' '));
        } catch (_) {}
      }
      ['error', 'warn'].forEach(function (k) {
        var orig = console[k]; console[k] = function () { send(k, arguments); orig.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) { send('uncaught', [e.message + ' @ ' + e.filename + ':' + e.lineno]); });
      window.addEventListener('unhandledrejection', function (e) { send('rejection', [e.reason]); });
    })();
    """#
    #else
    private static let debugLogging = ""
    #endif

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let dict = message.body as? [String: Any] {
            nav.handle(dict)
            return
        }
        guard let body = message.body as? String else { return }
        if body == "ctrlCleared" { ctrlActive = false }
        else if body == "ready" { isReady = true }
        else if body.hasPrefix("log:") { print("[web] \(body.dropFirst(4))") }
    }

    func js(_ source: String) { webView?.evaluateJavaScript(source, completionHandler: nil) }

    func key(_ name: String, ctrl: Bool = false) {
        js("window.__cc && window.__cc.key(\(Self.quote(name)), \(ctrl))")
    }

    func text(_ s: String) { js("window.__cc && window.__cc.text(\(Self.quote(s)))") }

    func toggleCtrl() {
        ctrlActive.toggle()
        js("window.__cc && (window.__cc.ctrl = \(ctrlActive))")
    }

    func dismissKeyboard() { js("window.__cc && window.__cc.blur()") }

    private static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}
