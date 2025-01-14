//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal

/// Holds the metadata of a Readium publication, as described in the Readium Web Publication
/// Manifest.
///
/// See. https://readium.org/webpub-manifest/
public struct Manifest: JSONEquatable, Hashable {
    public var context: [String] // @context

    public var metadata: Metadata

    public var links: [Link]

    /// Identifies a list of resources in reading order for the publication.
    public var readingOrder: [Link]

    /// Identifies resources that are necessary for rendering the publication.
    public var resources: [Link]

    public var subcollections: [String: [PublicationCollection]]

    /// Identifies the collection that contains a table of contents.
    public var tableOfContents: [Link] {
        get { subcollections["toc"]?.first?.links ?? [] }
        set {
            if newValue.isEmpty {
                subcollections.removeValue(forKey: "toc")
            } else {
                subcollections["toc"] = [PublicationCollection(links: newValue)]
            }
        }
    }

    public init(
        context: [String] = [],
        metadata: Metadata = Metadata(),
        links: [Link] = [],
        readingOrder: [Link] = [],
        resources: [Link] = [],
        tableOfContents: [Link] = [],
        subcollections: [String: [PublicationCollection]] = [:]
    ) {
        // Convenience to set the table of contents during construction
        var subcollections = subcollections
        if !tableOfContents.isEmpty {
            subcollections["toc"] = [PublicationCollection(links: tableOfContents)]
        }

        self.context = context
        self.metadata = metadata
        self.links = links
        self.readingOrder = readingOrder
        self.resources = resources
        self.subcollections = subcollections
    }

    /// Parses a Readium Web Publication Manifest.
    /// https://readium.org/webpub-manifest/schema/publication.schema.json
    ///
    /// If a non-fatal parsing error occurs, it will be logged through `warnings`.
    public init(json: Any, warnings: WarningLogger? = nil) throws {
        guard var json = JSONDictionary(json) else {
            throw JSONError.parsing(Publication.self)
        }

        context = parseArray(json.pop("@context"), allowingSingle: true)
        metadata = try Metadata(json: json.pop("metadata"), warnings: warnings)

        links = [Link](json: json.pop("links"), warnings: warnings)

        // `readingOrder` used to be `spine`, so we parse `spine` as a fallback.
        readingOrder = [Link](json: json.pop("readingOrder") ?? json.pop("spine"), warnings: warnings)
            .filter { $0.type != nil }
        resources = [Link](json: json.pop("resources"), warnings: warnings)
            .filter { $0.type != nil }

        // Parses sub-collections from remaining JSON properties.
        subcollections = PublicationCollection.makeCollections(json: json.json, warnings: warnings)
    }

    public var json: [String: Any] {
        makeJSON([
            "@context": encodeIfNotEmpty(context),
            "metadata": metadata.json,
            "links": links.json,
            "readingOrder": readingOrder.json,
            "resources": encodeIfNotEmpty(resources.json),
            "toc": encodeIfNotEmpty(tableOfContents.json),
        ], additional: PublicationCollection.serializeCollections(subcollections))
    }

    /// Returns whether this manifest conforms to the given Readium Web Publication Profile.
    public func conforms(to profile: Publication.Profile) -> Bool {
        guard !readingOrder.isEmpty else {
            return false
        }

        switch profile {
        case .audiobook:
            return readingOrder.allAreAudio
        case .divina:
            return readingOrder.allAreBitmap
        case .epub:
            // EPUB needs to be explicitly indicated in `conformsTo`, otherwise
            // it could be a regular Web Publication.
            return readingOrder.allAreHTML && metadata.conformsTo.contains(.epub)
        case .pdf:
            return readingOrder.all(matchMediaType: .pdf)
        default:
            break
        }

        return metadata.conformsTo.contains(profile)
    }

    /// Finds the first Link having the given `href` in the manifest's links.
    public func link(withHREF href: String) -> Link? {
        func deepFind(in linkLists: [Link]...) -> Link? {
            for links in linkLists {
                for link in links {
                    if link.href == href {
                        return link
                    } else if let child = deepFind(in: link.alternates, link.children) {
                        return child
                    }
                }
            }

            return nil
        }

        var link = deepFind(in: readingOrder, resources, links)
        if
            link == nil,
            let shortHREF = href.components(separatedBy: .init(charactersIn: "#?")).first,
            shortHREF != href
        {
            // Tries again, but without the anchor and query parameters.
            link = self.link(withHREF: shortHREF)
        }

        return link
    }

    /// Finds the first link with the given relation in the manifest's links.
    public func link(withRel rel: LinkRelation) -> Link? {
        readingOrder.first(withRel: rel)
            ?? resources.first(withRel: rel)
            ?? links.first(withRel: rel)
    }

    /// Finds all the links with the given relation in the manifest's links.
    public func links(withRel rel: LinkRelation) -> [Link] {
        (readingOrder + resources + links).filter(byRel: rel)
    }

    /// Makes a copy of the `Manifest`, after modifying some of its properties.
    @available(*, deprecated, message: "Make a mutable copy of the struct instead")
    public func copy(
        context: [String]? = nil,
        metadata: Metadata? = nil,
        links: [Link]? = nil,
        readingOrder: [Link]? = nil,
        resources: [Link]? = nil,
        tableOfContents: [Link]? = nil,
        subcollections: [String: [PublicationCollection]]? = nil
    ) -> Manifest {
        Manifest(
            context: context ?? self.context,
            metadata: metadata ?? self.metadata,
            links: links ?? self.links,
            readingOrder: readingOrder ?? self.readingOrder,
            resources: resources ?? self.resources,
            tableOfContents: tableOfContents ?? self.tableOfContents,
            subcollections: subcollections ?? self.subcollections
        )
    }
}
