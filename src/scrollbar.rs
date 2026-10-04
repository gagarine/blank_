use eframe::egui::{self, ScrollArea, Vec2};

#[derive(Default)]
pub struct ScrollBars {
    #[cfg(target_os = "macos")]
    native: Option<native::Bars>,
}
impl ScrollBars {
    pub fn attach(&mut self, cc: &eframe::CreationContext<'_>) {
        #[cfg(target_os = "macos")]
        {
            use raw_window_handle::{HasWindowHandle, RawWindowHandle};
            if let Ok(handle) = cc.window_handle()
                && let RawWindowHandle::AppKit(handle) = handle.as_raw()
            {
                let view = unsafe {
                    objc2::rc::Retained::retain(
                        handle.ns_view.cast::<objc2_app_kit::NSView>().as_ptr(),
                    )
                };
                if let Some(view) = view {
                    self.native = Some(native::Bars::new(view, &cc.egui_ctx));
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = cc;
    }
    pub fn area(&mut self, mut area: ScrollArea, ctx: &egui::Context) -> ScrollArea {
        #[cfg(target_os = "macos")]
        {
            if self.native.is_none() && ctx.input(|i| i.viewport().focused.unwrap_or(false)) {
                use objc2::MainThreadMarker;
                use objc2_app_kit::NSApplication;
                if let Some(mtm) = MainThreadMarker::new()
                    && let Some(view) = NSApplication::sharedApplication(mtm)
                        .keyWindow()
                        .and_then(|window| window.contentView())
                {
                    self.native = Some(native::Bars::new(view, ctx));
                }
            }
            if let Some(bars) = &self.native {
                area = area
                    .scroll_bar_visibility(egui::scroll_area::ScrollBarVisibility::AlwaysHidden);
                if let Some(offset) = bars.offset() {
                    area = area.scroll_offset(offset);
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = ctx;
        area
    }
    pub fn update(
        &mut self,
        rect: egui::Rect,
        content: Vec2,
        offset: Vec2,
        visible: bool,
        ctx: &egui::Context,
    ) {
        #[cfg(target_os = "macos")]
        if let Some(bars) = &self.native {
            bars.update(rect, content, offset, visible, ctx.zoom_factor());
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (rect, content, offset, visible, ctx);
    }
}
#[cfg(target_os = "macos")]
mod native {
    use super::*;
    use objc2::{
        DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained, sel,
    };
    use objc2_app_kit::{NSScroller, NSScrollerPart, NSScrollerStyle, NSView};
    use objc2_foundation::{NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize};
    use std::cell::{Cell, RefCell};
    struct Ivars {
        value: Cell<Option<f64>>,
        ctx: egui::Context,
    }
    define_class!(
        // NSObject has no additional subclass requirements; all access stays on the GUI thread.
        #[unsafe(super=NSObject)] #[thread_kind=MainThreadOnly] #[ivars=Ivars]
        struct Target;
        unsafe impl NSObjectProtocol for Target {}
        impl Target {
            #[unsafe(method(scrolled:))]
            fn scrolled(&self,sender:&NSScroller) {
                let step=sender.knobProportion()*0.9;
                let value=match sender.hitPart() {
                    NSScrollerPart::IncrementPage=>sender.doubleValue()+step,
                    NSScrollerPart::DecrementPage=>sender.doubleValue()-step,
                    _=>sender.doubleValue(),
                };
                self.ivars().value.set(Some(value.clamp(0.0,1.0)));self.ivars().ctx.request_repaint();
            }
        }
    );
    pub struct Bars {
        view: Retained<NSView>,
        controls: [Retained<NSScroller>; 2],
        targets: [Retained<Target>; 2],
        maximum: Cell<Vec2>,
        offset: Cell<Vec2>,
        window_title: RefCell<Option<String>>,
    }
    impl Bars {
        pub fn new(view: Retained<NSView>, ctx: &egui::Context) -> Self {
            let mtm = MainThreadMarker::new().unwrap();
            let targets: [Retained<Target>; 2] = std::array::from_fn(|_| {
                let target = Target::alloc(mtm).set_ivars(Ivars {
                    value: Cell::new(None),
                    ctx: ctx.clone(),
                });
                unsafe { msg_send![super(target), init] }
            });
            let controls = std::array::from_fn(|axis| {
                let frame = if axis == 0 {
                    NSRect::new(NSPoint::ZERO, NSSize::new(100.0, 12.0))
                } else {
                    NSRect::new(NSPoint::ZERO, NSSize::new(12.0, 100.0))
                };
                let control = NSScroller::initWithFrame(NSScroller::alloc(mtm), frame);
                control.setScrollerStyle(NSScrollerStyle::Overlay);
                unsafe {
                    control.setTarget(Some(&targets[axis]));
                    control.setAction(Some(sel!(scrolled:)));
                    view.addSubview(&control);
                }
                control.setHidden(true);
                control
            });
            Self {
                view,
                controls,
                targets,
                maximum: Cell::new(Vec2::ZERO),
                offset: Cell::new(Vec2::ZERO),
                window_title: RefCell::new(None),
            }
        }
        pub fn offset(&self) -> Option<Vec2> {
            let mut offset = self.offset.get();
            let mut changed = false;
            for axis in 0..2 {
                if let Some(value) = self.targets[axis].ivars().value.take() {
                    offset[axis] = value as f32 * self.maximum.get()[axis];
                    changed = true;
                }
            }
            changed.then_some(offset)
        }
        pub fn update(
            &self,
            rect: egui::Rect,
            content: Vec2,
            offset: Vec2,
            visible: bool,
            scale: f32,
        ) {
            if let Some(window) = self.view.window() {
                let title = window.title().to_string();
                let mut previous = self.window_title.borrow_mut();
                if previous.as_ref() != Some(&title) {
                    let app = objc2_app_kit::NSApplication::sharedApplication(
                        MainThreadMarker::new().unwrap(),
                    );
                    window.setExcludedFromWindowsMenu(false);
                    if previous.is_none() {
                        app.addWindowsItem_title_filename(&window, &window.title(), false);
                    } else {
                        app.changeWindowsItem_title_filename(&window, &window.title(), false);
                    }
                    *previous = Some(title);
                }
            }
            let maximum = (content - rect.size()).max(Vec2::ZERO);
            self.maximum.set(maximum);
            self.offset.set(offset);
            for axis in 0..2 {
                let control = &self.controls[axis];
                let show = visible && maximum[axis] > 1.0;
                control.setEnabled(show);
                control.setHidden(!show);
                if !show {
                    continue;
                }
                let frame = if axis == 0 {
                    egui::Rect::from_min_size(
                        egui::pos2(rect.left(), rect.bottom() - 12.0),
                        egui::vec2(rect.width() - 12.0, 12.0),
                    )
                } else {
                    egui::Rect::from_min_size(
                        egui::pos2(rect.right() - 12.0, rect.top()),
                        egui::vec2(
                            12.0,
                            rect.height() - if maximum.x > 0.0 { 12.0 } else { 0.0 },
                        ),
                    )
                };
                let y = if self.view.isFlipped() {
                    frame.top() * scale
                } else {
                    self.view.bounds().size.height as f32 - frame.bottom() * scale
                };
                control.setFrame(NSRect::new(
                    NSPoint::new((frame.left() * scale) as f64, y as f64),
                    NSSize::new(
                        (frame.width() * scale) as f64,
                        (frame.height() * scale) as f64,
                    ),
                ));
                control
                    .setKnobProportion((rect.size()[axis] / content[axis]).clamp(0.0, 1.0) as f64);
                control.setDoubleValue((offset[axis] / maximum[axis]).clamp(0.0, 1.0) as f64);
            }
        }
    }
    impl Drop for Bars {
        fn drop(&mut self) {
            if let Some(window) = self.view.window() {
                objc2_app_kit::NSApplication::sharedApplication(MainThreadMarker::new().unwrap())
                    .removeWindowsItem(&window);
            }
            for control in &self.controls {
                control.removeFromSuperview();
            }
        }
    }
}
