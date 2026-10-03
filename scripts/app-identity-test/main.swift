import Foundation

// Prints what AppIdentity resolves to when this binary runs as the executable
// of a given app bundle (see scripts/app_identity_test.sh).
print("bundleID=\(AppIdentity.bundleID)")
print("dataDirectoryName=\(AppIdentity.dataDirectoryName)")
print("displayName=\(AppIdentity.displayName)")
print("learnFromEditsDefault=\(AppIdentity.learnFromEditsDefault ? 1 : 0)")
print("userAgent=\(AppIdentity.userAgent)")
