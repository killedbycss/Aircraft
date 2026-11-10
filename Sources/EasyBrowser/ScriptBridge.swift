import Foundation
import WebKit

@MainActor
public protocol ScriptBridgeDelegate: AnyObject {
    func scriptBridge(_ bridge: ScriptBridge, didReceiveAction action: String, payload: [String: Any])
}

/// Модуль для взаимодействия Swift <-> JavaScript через WKScriptMessageHandler
@MainActor
public final class ScriptBridge: NSObject, WKScriptMessageHandler {
    public static let messageHandlerName = "browserBridge"
    private static let modStorageKey = "aircraftModStorageV1"
    public weak var delegate: ScriptBridgeDelegate?

    public func configure(userContentController: WKUserContentController) {
        userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        userContentController.add(self, name: Self.messageHandlerName)

        // Стабильный API для пользовательских модификаций.
        let storageJSON = Self.persistedStorageJSON()
        let scriptSource = """
        (() => {
          const nativeBridge = window.webkit?.messageHandlers?.browserBridge;
          const post = (action, payload = {}) => {
            if (!nativeBridge) return false;
            nativeBridge.postMessage({ action, ...payload });
            return true;
          };
          const values = \(storageJSON);
          const storage = Object.freeze({
            get: (key, fallback = null) => Object.prototype.hasOwnProperty.call(values, key) ? values[key] : fallback,
            getAll: () => structuredClone(values),
            set: (key, value) => {
              values[key] = value;
              post("modStorageSet", { key, value });
              window.dispatchEvent(new CustomEvent("aircraft:storage", { detail: { key, value } }));
            },
            remove: (key) => {
              delete values[key];
              post("modStorageRemove", { key });
              window.dispatchEvent(new CustomEvent("aircraft:storage", { detail: { key, removed: true } }));
            }
          });
          window.aircraft = Object.freeze({
            version: "0.2",
            post,
            storage,
            closeTab: () => post("closeTab"),
            newTab: () => post("newTab"),
            openTab: (url = "") => post("openTab", { url }),
            reload: () => post("reloadTab"),
            openSpotlight: () => post("openSpotlight"),
            openSettings: () => post("openSettings"),
            toggleReaderMode: () => post("toggleReaderMode"),
            enableDevTools: () => post("enableDevTools")
          });
          window.dispatchEvent(new CustomEvent("aircraft:ready", { detail: { version: "0.2" } }));
        })();
        """
        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(userScript)
    }

    public static func setStoredValue(_ value: Any, for key: String) {
        guard !key.isEmpty else { return }
        var storage = persistedStorage()
        storage[key] = value
        persist(storage)
    }

    public static func removeStoredValue(for key: String) {
        var storage = persistedStorage()
        storage.removeValue(forKey: key)
        persist(storage)
    }

    private static func persistedStorage() -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: modStorageKey),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    private static func persistedStorageJSON() -> String {
        let storage = persistedStorage()
        guard JSONSerialization.isValidJSONObject(storage),
              let data = try? JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func persist(_ storage: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(storage),
              let data = try? JSONSerialization.data(withJSONObject: storage) else { return }
        UserDefaults.standard.set(data, forKey: modStorageKey)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName else { return }

        if let dict = message.body as? [String: Any], let action = dict["action"] as? String {
            delegate?.scriptBridge(self, didReceiveAction: action, payload: dict)
        } else if let action = message.body as? String {
            delegate?.scriptBridge(self, didReceiveAction: action, payload: [:])
        }
    }

    /// Загрузка пользовательских JS-скриптов
    public func injectCustomScript(_ source: String, into userContentController: WKUserContentController, at injectionTime: WKUserScriptInjectionTime = .atDocumentEnd) {
        let script = WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: true)
        userContentController.addUserScript(script)
    }

    /// Загрузка пользовательских CSS-стилей
    public func injectCSS(_ css: String, into userContentController: WKUserContentController) {
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let jsSource = """
        (function() {
            var style = document.createElement('style');
            style.innerHTML = "\(escapedCSS)";
            document.head.appendChild(style);
        })();
        """
        injectCustomScript(jsSource, into: userContentController, at: .atDocumentEnd)
    }
}
