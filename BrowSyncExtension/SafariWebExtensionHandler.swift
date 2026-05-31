// SafariWebExtensionHandler.swift
// BrowSync Safari Extension — Native message handler

import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "com.ct106.browsync.extension", category: "SafariHandler")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]

        logger.log("Received message from Safari extension: \(String(describing: message))")

        // Echo back an ack (the JS background does not rely on native handler for WS communication)
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["status": "ok"]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
