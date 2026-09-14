import Foundation

public struct WebDAVItem: Sendable {
    public let href: String
    public let displayName: String?
    public let isDirectory: Bool
    public let contentLength: Int64
    public let etag: String?
    public let lastModified: String?
}

public final class WebDAVXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var items: [WebDAVItem] = []
    private var currentHref: String = ""
    private var currentDisplayName: String?
    private var currentLength: Int64 = 0
    private var currentEtag: String?
    private var currentLastModified: String?
    private var isCollection: Bool = false
    private var currentElement: String = ""
    private var currentText: String = ""

    public func parse(data: Data) -> [WebDAVItem] {
        items.removeAll()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        currentElement = name
        currentText = ""

        if name.hasSuffix("response") {
            currentHref = ""
            currentDisplayName = nil
            currentLength = 0
            currentEtag = nil
            currentLastModified = nil
            isCollection = false
        } else if name.hasSuffix("collection") {
            isCollection = true
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.hasSuffix("href") {
            currentHref = text
        } else if name.hasSuffix("displayname") {
            currentDisplayName = text
        } else if name.hasSuffix("getcontentlength") {
            currentLength = Int64(text) ?? 0
        } else if name.hasSuffix("getetag") {
            currentEtag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else if name.hasSuffix("getlastmodified") {
            currentLastModified = text
        } else if name.hasSuffix("response") {
            if !currentHref.isEmpty {
                let item = WebDAVItem(
                    href: currentHref,
                    displayName: currentDisplayName,
                    isDirectory: isCollection,
                    contentLength: currentLength,
                    etag: currentEtag,
                    lastModified: currentLastModified
                )
                items.append(item)
            }
        }
    }
}
