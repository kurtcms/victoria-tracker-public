import SwiftUI

struct RootView: View {
  @Bindable var model: AppModel
  var body: some View {
    NavigationStack {
      Group {
        if let configurationError {
          ContentUnavailableView(
            "Connect Supabase", systemImage: "externaldrive.badge.icloud",
            description: Text(configurationError))
        } else if model.loading {
          ProgressView("Opening your family’s day…")
        } else if model.userID == nil {
          AuthView(model: model).navigationTitle("Victoria Tracker")
        } else if model.allChildren.isEmpty {
          FamilyView(model: model).navigationTitle("Your family")
        } else {
          TrackerTabs(model: model)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.userID != nil && model.allChildren.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
              Task { await model.signOut() }
            }
            .disabled(model.busy)
          }
        }
      }
    }
  }
  private var configurationError: String? {
    do {
      _ = try Configuration.load()
      return nil
    } catch { return error.localizedDescription }
  }
}

struct StatusMessages: View {
  let model: AppModel
  var body: some View {
    if let error = model.error {
      Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
        .accessibilityIdentifier("errorMessage")
    }
    if let notice = model.notice {
      Label(notice, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
        .accessibilityIdentifier("noticeMessage")
    }
  }
}

struct AuthView: View {
  @Bindable var model: AppModel
  @State private var email = ""
  @State private var password = ""
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  var body: some View {
    Form {
      Section {
        Image(systemName: "heart.circle.fill").font(.system(size: 56)).foregroundStyle(.pink).frame(
          maxWidth: .infinity)
        Text("Parenting is hands-on. Tracking shouldn’t be.").font(.title2.bold())
        Text("Say it. We’ll log it.").foregroundStyle(
          .secondary)
      }
      Section("Your account") {
        TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        SecureField("Password", text: $password).textContentType(.password)
      }
      Section {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(spacing: 12) {
            signInButton
            createAccountButton
          }
        } else {
          HStack(spacing: 12) {
            signInButton
            createAccountButton
          }
        }
        Text("New accounts need a password of at least 12 characters and email confirmation.").font(
          .footnote
        ).foregroundStyle(.secondary)
      }
      Section {
        StatusMessages(model: model)
        if model.busy { ProgressView() }
      }
    }
  }
  private var signInButton: some View {
    Button {
      Task {
        await model.run {
          try await Backend.shared.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
          password = ""
        }
      }
    } label: {
      Text("Sign in")
    }
    .buttonStyle(AuthButtonStyle(primary: true))
    .accessibilityIdentifier("signInButton")
    .disabled(model.busy || email.isEmpty || password.isEmpty)
  }
  private var createAccountButton: some View {
    Button {
      Task {
        await model.run {
          model.notice = try await Backend.shared.signUp(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
          password = ""
        }
      }
    } label: {
      Text("Create account")
    }
    .buttonStyle(AuthButtonStyle(primary: false))
    .accessibilityIdentifier("createAccountButton")
    .disabled(model.busy || email.isEmpty || password.count < 12)
  }
}

private struct AuthButtonStyle: ButtonStyle {
  let primary: Bool
  @Environment(\.isEnabled) private var isEnabled
  private let rose = Color(red: 0.72, green: 0.23, blue: 0.38)
  func makeBody(configuration: ButtonStyleConfiguration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .padding(.horizontal, 10).padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 46)
      .foregroundStyle(primary ? .white : rose)
      .background(primary ? rose : .clear, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(rose, lineWidth: primary ? 0 : 1.5))
      .contentShape(RoundedRectangle(cornerRadius: 12))
      .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
  }
}

struct FamilyView: View {
  @Bindable var model: AppModel
  @State private var invite = ""
  @State private var babyName = ""
  var body: some View {
    Form {
      Section("Welcome to your family") {
        Text(
          "The first parent creates the family. The second parent joins with the invite code from the first parent’s phone."
        )
        TextField("Baby’s name", text: $babyName).textContentType(.givenName)
        Button("Create your family") {
          Task { await model.run { try await Backend.shared.createFamily(name: babyName) } }
        }.disabled(
          model.busy || babyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || babyName.count > 80)
      }
      Section("Join your partner") {
        TextField("Invite code", text: $invite).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Join family") {
          Task { await model.run { try await Backend.shared.joinFamily(token: invite) } }
        }.disabled(model.busy || invite.isEmpty)
      }
      Section {
        StatusMessages(model: model)
        if model.busy { ProgressView() }
        Button("Refresh family access") { Task { await model.refresh() } }
      }
    }
  }
}
