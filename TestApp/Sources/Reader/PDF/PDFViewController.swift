//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumAdapterGCDWebServer
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

@available(iOS 16.0, *)
final class PDFViewController: VisualReaderViewController<PDFNavigatorViewController> {
    private let preferencesStore: AnyUserPreferencesStore<PDFPreferences>
    var editMenuInteraction: UIEditMenuInteraction?

    init(
        publication: Publication,
        locator: Locator?,
        bookId: Book.Id,
        books: BookRepository,
        bookmarks: BookmarkRepository,
        highlights: HighlightRepository,
        initialPreferences: PDFPreferences,
        preferencesStore: AnyUserPreferencesStore<PDFPreferences>
    ) throws {
        self.preferencesStore = preferencesStore

        let navigator = try PDFNavigatorViewController(
            publication: publication,
            initialLocation: locator,
            config: PDFNavigatorViewController.Configuration(
                preferences: initialPreferences
            ),
            httpServer: GCDHTTPServer.shared
        )

        super.init(navigator: navigator, publication: publication, bookId: bookId, books: books, bookmarks: bookmarks, highlights: highlights)

        navigator.delegate = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        editMenuInteraction = UIEditMenuInteraction(delegate: self)
        self.view.addInteraction(editMenuInteraction!)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        longPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        self.view.addGestureRecognizer(longPress)
    }

    @objc func didLongPress(_ recognizer: UIGestureRecognizer) {
        let location = recognizer.location(in: self.view)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)

        editMenuInteraction?.presentEditMenu(with: configuration)
    }

    override func presentUserPreferences() {
        Task {
            let userPrefs = await UserPreferences(
                model: UserPreferencesViewModel(
                    bookId: bookId,
                    preferences: try! preferencesStore.preferences(for: bookId),
                    configurable: navigator,
                    store: preferencesStore
                ),
                onClose: { [weak self] in
                    self?.dismiss(animated: true)
                }
            )
            let vc = UIHostingController(rootView: userPrefs)
            vc.modalPresentationStyle = .formSheet
            present(vc, animated: true)
        }
    }
}

@available(iOS 16.0, *)
extension PDFViewController: PDFNavigatorDelegate {}

@available(iOS 16.0, *)
extension PDFViewController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        
        var actions = suggestedActions
        
        let customActions = UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "chatGPT") { _ in
                print("chatGPT")
            },
        ])
        
        actions.append(customActions)
        
        return UIMenu(children: actions)
    }
}
