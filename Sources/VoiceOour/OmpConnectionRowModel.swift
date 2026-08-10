import VoiceMac

struct OmpConnectionRowModel: Identifiable {
    let providerID: String
    let displayName: String
    let connection: OmpProviderConnection?
    let subscription: OmpSubscription?

    var id: String { providerID }
}
