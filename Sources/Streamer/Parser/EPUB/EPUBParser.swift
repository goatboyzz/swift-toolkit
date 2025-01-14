//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import Fuzi
import ReadiumShared

/// Epub related constants.
private enum EPUBConstant {
    /// Media Overlays URL.
    static let mediaOverlayURL = "media-overlay?resource="
}

/// Errors thrown during the parsing of the EPUB
///
/// - wrongMimeType: The mimetype file is missing or its content differs from
///                 "application/epub+zip" (expected).
/// - missingFile: A file is missing from the container at `path`.
/// - xmlParse: An XML parsing error occurred.
/// - missingElement: An XML element is missing.
public enum EPUBParserError: Error {
    /// The mimetype of the EPUB is not valid.
    case wrongMimeType
    case missingFile(path: String)
    case xmlParse(underlyingError: Error)
    /// Missing rootfile in `container.xml`.
    case missingRootfile
}

extension EPUBParser: Loggable {}

/// An EPUB container parser that extracts the information from the relevant
/// files and builds a `Publication` instance out of it.
public final class EPUBParser: PublicationParser {
    private let reflowablePositionsStrategy: EPUBPositionsService.ReflowableStrategy

    /// - Parameter reflowablePositionsStrategy: Strategy used to calculate the number of positions in a reflowable resource.
    public init(reflowablePositionsStrategy: EPUBPositionsService.ReflowableStrategy = .recommended) {
        self.reflowablePositionsStrategy = reflowablePositionsStrategy
    }

    public func parse(asset: PublicationAsset, fetcher: Fetcher, warnings: WarningLogger?) throws -> Publication.Builder? {
        guard asset.mediaType() == .epub else {
            return nil
        }

        let opfHREF = try EPUBContainerParser(fetcher: fetcher).parseOPFHREF()

        // `Encryption` indexed by HREF.
        let encryptions = (try? EPUBEncryptionParser(fetcher: fetcher))?.parseEncryptions() ?? [:]

        // Extracts metadata and links from the OPF.
        let components = try OPFParser(fetcher: fetcher, opfHREF: opfHREF, encryptions: encryptions).parsePublication()
        let metadata = components.metadata
        let links = components.readingOrder + components.resources

        let userProperties = UserProperties()

        return Publication.Builder(
            mediaType: .epub,
            manifest: Manifest(
                metadata: metadata,
                readingOrder: components.readingOrder,
                resources: components.resources,
                subcollections: parseCollections(in: fetcher, links: links)
            ),
            fetcher: TransformingFetcher(fetcher: fetcher, transformers: [
                EPUBDeobfuscator(publicationId: metadata.identifier ?? "").deobfuscate(resource:),
                EPUBHTMLInjector(metadata: components.metadata, userProperties: userProperties).inject(resource:),
            ]),
            servicesBuilder: .init(
                content: DefaultContentService.makeFactory(
                    resourceContentIteratorFactories: [
                        HTMLResourceContentIterator.Factory(),
                    ]
                ),
                positions: EPUBPositionsService.makeFactory(reflowableStrategy: reflowablePositionsStrategy),
                search: _StringSearchService.makeFactory()
            ),
            setupPublication: { publication in
                publication.userProperties = userProperties
                publication.userSettingsUIPreset = Self.userSettingsPreset(for: publication.metadata)
            }
        )
    }

    private func parseCollections(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        var collections = parseNavigationDocument(in: fetcher, links: links)
        if collections["toc"]?.first?.links.isEmpty != false {
            // Falls back on the NCX tables.
            collections.merge(parseNCXDocument(in: fetcher, links: links), uniquingKeysWith: { first, _ in first })
        }
        return collections
    }

    // MARK: - Internal Methods.

    /// Attempt to fill the `Publication`'s `tableOfContent`, `landmarks`, `pageList` and `listOfX` links collections using the navigation document.
    private func parseNavigationDocument(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        // Get the link in the readingOrder pointing to the Navigation Document.
        guard
            let navLink = links.first(withRel: .contents),
            let navURI = RelativeURL(string: navLink.href),
            let navDocumentData = try? fetcher.readData(at: navURI)
        else {
            return [:]
        }

        // Get the location of the navigation document in order to normalize href paths.
        let navigationDocument = NavigationDocumentParser(data: navDocumentData, at: navURI)

        var collections: [String: [PublicationCollection]] = [:]
        func addCollection(_ type: NavigationDocumentParser.NavType, role: String) {
            let links = navigationDocument.links(for: type)
            if !links.isEmpty {
                collections[role] = [PublicationCollection(links: links)]
            }
        }

        addCollection(.tableOfContents, role: "toc")
        addCollection(.pageList, role: "pageList")
        addCollection(.landmarks, role: "landmarks")
        addCollection(.listOfAudiofiles, role: "loa")
        addCollection(.listOfIllustrations, role: "loi")
        addCollection(.listOfTables, role: "lot")
        addCollection(.listOfVideos, role: "lov")

        return collections
    }

    /// Attempt to fill `Publication.tableOfContent`/`.pageList` using the NCX
    /// document. Will only modify the Publication if it has not be filled
    /// previously (using the Navigation Document).
    private func parseNCXDocument(in fetcher: Fetcher, links: [Link]) -> [String: [PublicationCollection]] {
        // Get the link in the readingOrder pointing to the NCX document.
        guard
            let ncxLink = links.first(withMediaType: .ncx),
            let ncxURI = RelativeURL(string: ncxLink.href),
            let ncxDocumentData = try? fetcher.readData(at: ncxURI)
        else {
            return [:]
        }

        let ncx = NCXParser(data: ncxDocumentData, at: ncxURI)

        var collections: [String: [PublicationCollection]] = [:]
        func addCollection(_ type: NCXParser.NavType, role: String) {
            let links = ncx.links(for: type)
            if !links.isEmpty {
                collections[role] = [PublicationCollection(links: links)]
            }
        }

        addCollection(.tableOfContents, role: "toc")
        addCollection(.pageList, role: "pageList")

        return collections
    }

    static func userSettingsPreset(for metadata: Metadata) -> [ReadiumCSSName: Bool] {
        let isCJK: Bool = {
            guard
                metadata.languages.count == 1,
                let language = metadata.languages.first?.split(separator: "-").first.map(String.init)?.lowercased()
            else {
                return false
            }
            return ["zh", "ja", "ko"].contains(language)
        }()

        switch metadata.effectiveReadingProgression {
        case .rtl, .btt:
            if isCJK {
                // CJK vertical
                return [
                    .scroll: true,
                    .columnCount: false,
                    .textAlignment: false,
                    .hyphens: false,
                    .paraIndent: false,
                    .wordSpacing: false,
                    .letterSpacing: false,
                ]

            } else {
                // RTL
                return [
                    .hyphens: false,
                    .wordSpacing: false,
                    .letterSpacing: false,
                    .ligatures: true,
                ]
            }

        case .ltr, .ttb, .auto:
            if isCJK {
                // CJK horizontal
                return [
                    .textAlignment: false,
                    .hyphens: false,
                    .paraIndent: false,
                    .wordSpacing: false,
                    .letterSpacing: false,
                ]

            } else {
                // LTR
                return [
                    .hyphens: false,
                    .ligatures: false,
                ]
            }
        }
    }

    /// Parse the mediaOverlays informations contained in the ressources then
    /// parse the associted SMIL files to populate the MediaOverlays objects
    /// in each of the ReadingOrder's Links.
    private func parseMediaOverlay(from fetcher: Fetcher, to publication: inout Publication) throws {
        // FIXME: For now we don't fill the media-overlays anymore, since it was only half implemented and the API will change
//        let mediaOverlays = publication.resources.filter(byType: .smil)
//
//        guard !mediaOverlays.isEmpty else {
//            log(.info, "No media-overlays found in the Publication.")
//            return
//        }
//        for mediaOverlayLink in mediaOverlays {
//            let node = MediaOverlayNode()
//
//            guard let smilData = try? fetcher.data(at: mediaOverlayLink.href),
//                let smilXml = try? XMLDocument(data: smilData) else
//            {
//                throw OPFParserError.invalidSmilResource
//            }
//
//            smilXml.definePrefix("smil", forNamespace: "http://www.w3.org/ns/SMIL")
//            smilXml.definePrefix("epub", forNamespace: "http://www.idpf.org/2007/ops")
//            guard let body = smilXml.firstChild(xpath: "./smil:body") else {
//                continue
//            }
//
//            node.role.append("section")
//            if let textRef = body.attr("textref") { // Prevent the crash on the japanese book
//                node.text = HREF(textRef, relativeTo: mediaOverlayLink.href).string
//            }
//            // get body parameters <par>a
//            let href = mediaOverlayLink.href
//            SMILParser.parseParameters(in: body, withParent: node, base: href)
//            SMILParser.parseSequences(in: body, withParent: node, publicationReadingOrder: &publication.readingOrder, base: href)
        // "/??/xhtml/mo-002.xhtml#mo-1" => "/??/xhtml/mo-002.xhtml"

//            guard let baseHref = node.text?.components(separatedBy: "#")[0],
//                let link = publication.readingOrder.first(where: { baseHref.contains($0.href) }) else
//            {
//                continue
//            }
//            link.mediaOverlays.append(node)
//            link.properties.mediaOverlay = EPUBConstant.mediaOverlayURL + link.href
//        }
    }
}
