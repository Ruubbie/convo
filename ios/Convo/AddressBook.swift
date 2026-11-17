import Contacts

/// Names from the iPhone's contacts, looked up by phone number.
enum AddressBook {
    /// Matching on the last 9 digits ignores how a number was saved ("+31 6 …", "06 …", "0031 6 …").
    static func key(_ phone: String) -> String? {
        let digits = phone.filter(\.isWholeNumber)
        return digits.count >= 7 ? String(digits.suffix(9)) : nil
    }

    /// Asks for access the first time; returns no names if it isn't given.
    static func load() async -> [String: String] {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return [:] }
        return await Task.detached {
            var names: [String: String] = [:]
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                guard let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty else { return }
                for number in contact.phoneNumbers {
                    if let k = AddressBook.key(number.value.stringValue), names[k] == nil { names[k] = name }
                }
            }
            return names
        }.value
    }
}
