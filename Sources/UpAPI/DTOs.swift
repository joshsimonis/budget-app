import Foundation

// JSON:API shapes returned by https://api.up.com.au/api/v1. Unknown fields are ignored and
// enum-like values are kept as strings, so new values from Up don't break decoding.

struct UpMoney: Decodable {
    let currencyCode: String
    let value: String
    let valueInBaseUnits: Int64
}

struct UpIdentifier: Decodable {
    let type: String
    let id: String
}

struct UpToOne: Decodable {
    let data: UpIdentifier?
}

struct UpToMany: Decodable {
    let data: [UpIdentifier]
}

struct UpLinks: Decodable {
    let prev: String?
    let next: String?
}

struct UpList<Resource: Decodable>: Decodable {
    let data: [Resource]
    let links: UpLinks?
}

struct UpSingle<Resource: Decodable>: Decodable {
    let data: Resource
}

struct UpPing: Decodable {
    struct Meta: Decodable {
        let id: String
        let statusEmoji: String?
    }

    let meta: Meta
}

struct UpErrorBody: Decodable {
    struct Item: Decodable {
        let status: String?
        let title: String?
        let detail: String?
    }

    let errors: [Item]
}

struct UpAccountResource: Decodable {
    struct Attributes: Decodable {
        let displayName: String
        let accountType: String
        let ownershipType: String?
        let balance: UpMoney
        let createdAt: String?
    }

    let id: String
    let attributes: Attributes
}

struct UpTransactionResource: Decodable {
    struct Attributes: Decodable {
        struct RoundUp: Decodable {
            let amount: UpMoney
        }

        let status: String
        let rawText: String?
        let description: String
        let message: String?
        let roundUp: RoundUp?
        let amount: UpMoney
        let foreignAmount: UpMoney?
        let settledAt: String?
        let createdAt: String
        let transactionType: String?
        let deepLinkURL: String?
    }

    struct Relationships: Decodable {
        let account: UpToOne
        let transferAccount: UpToOne?
        let category: UpToOne?
        let parentCategory: UpToOne?
        let tags: UpToMany?
    }

    let id: String
    let attributes: Attributes
    let relationships: Relationships
}

struct UpCategoryResource: Decodable {
    struct Attributes: Decodable {
        let name: String
    }

    struct Relationships: Decodable {
        let parent: UpToOne?
    }

    let id: String
    let attributes: Attributes
    let relationships: Relationships?
}

struct UpTagResource: Decodable {
    let id: String
}
