//! Save confirmation uses a parented native sheet, with no decorative app icon.
#[derive(Clone, Copy)]
pub enum Choice {
    Save,
    Discard,
    Cancel,
}

#[derive(Clone)]
pub struct Confirmation {
    #[cfg(target_os = "macos")]
    parent: Option<objc2::rc::Retained<objc2_app_kit::NSWindow>>,
    #[cfg(not(target_os = "macos"))]
    dialog: rfd::MessageDialog,
}

impl Confirmation {
    pub fn active_window() -> Self {
        #[cfg(target_os = "macos")]
        {
            Self { parent: None }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {
                dialog: rfd::MessageDialog::new(),
            }
        }
    }
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        #[cfg(target_os = "macos")]
        {
            use raw_window_handle::{HasWindowHandle, RawWindowHandle};
            let parent = cc.window_handle().ok().and_then(|handle| {
                let RawWindowHandle::AppKit(handle) = handle.as_raw() else {
                    return None;
                };
                // eframe owns a live NSView on the GUI thread. Retain its window
                // for the lifetime of the app's confirmation service.
                unsafe {
                    handle
                        .ns_view
                        .cast::<objc2_app_kit::NSView>()
                        .as_ref()
                        .window()
                }
            });
            Self { parent }
        }
        #[cfg(not(target_os = "macos"))]
        Self {
            dialog: rfd::MessageDialog::new().set_parent(cc),
        }
    }

    pub fn ask(&self, description: &str, closing: bool) -> Choice {
        let labels = if closing {
            ["Save and close", "Discard and close", "Keep writing"]
        } else {
            ["Save", "Discard", "Keep writing"]
        };
        #[cfg(target_os = "macos")]
        {
            use objc2::{AnyThread, MainThreadMarker, rc::autoreleasepool};
            use objc2_app_kit::{
                NSAlert, NSAlertFirstButtonReturn, NSAlertSecondButtonReturn, NSApplication,
                NSImage,
            };
            use objc2_foundation::{NSSize, NSString};
            let mtm = MainThreadMarker::new().expect("confirmations run on the GUI thread");
            autoreleasepool(|_| {
                let alert = NSAlert::new(mtm);
                alert.setMessageText(&NSString::from_str("Save your writing?"));
                alert.setInformativeText(&NSString::from_str(description));
                // nil restores the app icon. An empty image explicitly removes it.
                let image = NSImage::initWithSize(NSImage::alloc(), NSSize::new(0.0, 0.0));
                unsafe { alert.setIcon(Some(&image)) };
                for (index, label) in labels.into_iter().enumerate() {
                    let button = alert.addButtonWithTitle(&NSString::from_str(label));
                    button.setKeyEquivalent(&NSString::from_str(match index {
                        0 => "\r",
                        2 => "\u{1b}",
                        _ => "",
                    }));
                }
                let parent = self
                    .parent
                    .clone()
                    .or_else(|| NSApplication::sharedApplication(mtm).keyWindow());
                if let Some(parent) = &parent {
                    let completion = block2::StackBlock::new(move |result| {
                        NSApplication::sharedApplication(mtm).stopModalWithCode(result);
                    });
                    alert.beginSheetModalForWindow_completionHandler(parent, Some(&completion));
                }
                match alert.runModal() {
                    response if response == NSAlertFirstButtonReturn => Choice::Save,
                    response if response == NSAlertSecondButtonReturn => Choice::Discard,
                    _ => Choice::Cancel,
                }
            })
        }
        #[cfg(not(target_os = "macos"))]
        match self
            .dialog
            .clone()
            .set_title("Save your writing?")
            .set_description(description)
            .set_buttons(rfd::MessageButtons::YesNoCancelCustom(
                labels[0].into(),
                labels[1].into(),
                labels[2].into(),
            ))
            .show()
        {
            rfd::MessageDialogResult::Yes => Choice::Save,
            rfd::MessageDialogResult::No => Choice::Discard,
            rfd::MessageDialogResult::Custom(label) if label == labels[0] => Choice::Save,
            rfd::MessageDialogResult::Custom(label) if label == labels[1] => Choice::Discard,
            _ => Choice::Cancel,
        }
    }
}
