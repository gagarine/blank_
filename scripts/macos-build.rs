fn main() {
    // Cargo must relink cached executables and dylibs when their OS minimum changes.
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
}
