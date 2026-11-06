#[cfg(target_os = "windows")]
unsafe extern "C" {
    fn cgp_windows_dns_filter_open(result: *mut usize) -> u32;
    fn cgp_windows_dns_filter_close(handle: usize) -> u32;
}
pub struct Firewall {
    handle: usize,
}
impl Firewall {
    pub fn start() -> Result<Self, String> {
        #[cfg(target_os = "windows")]
        {
            let mut handle = 0;
            let code = unsafe { cgp_windows_dns_filter_open(&mut handle) };
            if code != 0 {
                return Err(format!("WFP DNS filter failed: 0x{code:08x}"));
            }
            Ok(Self { handle })
        }
        #[cfg(not(target_os = "windows"))]
        {
            Err("Use the native PF adapter on macOS".into())
        }
    }
}
impl Drop for Firewall {
    fn drop(&mut self) {
        #[cfg(target_os = "windows")]
        unsafe {
            cgp_windows_dns_filter_close(self.handle);
        }
        #[cfg(not(target_os = "windows"))]
        let _ = self.handle;
    }
}
