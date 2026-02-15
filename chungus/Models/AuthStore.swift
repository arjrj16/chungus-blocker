import Foundation
import Observation
import Supabase

@Observable
final class AuthStore {
    var isLoggedIn: Bool = false
    var isDemo: Bool = false
    var userEmail: String = ""

    func login(email: String, demo: Bool = false) {
        isLoggedIn = true
        isDemo = demo
        userEmail = email
    }

    func logout() async {
        if !isDemo {
            try? await supabaseClient.auth.signOut()
        }
        isLoggedIn = false
        isDemo = false
        userEmail = ""
    }

    func listenForAuthChanges() async {
        for await state in supabaseClient.auth.authStateChanges {
            if isDemo { continue }
            if [.initialSession, .signedIn, .signedOut].contains(state.event) {
                isLoggedIn = state.session != nil
                userEmail = state.session?.user.email ?? ""
            }
        }
    }
}
