fn main() {
    println!("cargo:rerun-if-changed=native/windows.c");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        cc::Build::new()
            .file("native/windows.c")
            .compile("gptproxy_windows");
        println!("cargo:rustc-link-lib=fwpuclnt");
    }
}
