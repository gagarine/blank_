//! AppKit menus live on the GUI thread; menu events wake the idle event loop.
use crate::commands::Command;
use eframe::egui;
use muda::{
    Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu,
    accelerator::{Accelerator, Code, Modifiers},
};
use std::sync::mpsc::{self, Receiver};
pub struct NativeMenus {
    _menu: Menu,
    pub rx: Receiver<Command>,
    items: Vec<(Command, MenuItem, bool)>,
}
impl NativeMenus {
    pub fn new(ctx: egui::Context) -> muda::Result<Self> {
        let menu = Menu::new();
        let mut items = Vec::new();
        let app = Submenu::new("blank_", true);
        app.append_items(&[
            &PredefinedMenuItem::about(Some("About blank_"), None),
            &PredefinedMenuItem::separator(),
            &PredefinedMenuItem::services(None),
            &PredefinedMenuItem::separator(),
            &PredefinedMenuItem::hide(None),
            &PredefinedMenuItem::hide_others(None),
            &PredefinedMenuItem::show_all(None),
            &PredefinedMenuItem::separator(),
        ])?;
        let quit = item(Command::Quit);
        app.append(&quit)?;
        items.push((Command::Quit, quit, true));
        menu.append(&app)?;
        for (title, commands) in [
            (
                "File",
                &[
                    Command::New,
                    Command::Open,
                    Command::Save,
                    Command::SaveAs,
                    Command::Export,
                    Command::Close,
                ][..],
            ),
            (
                "Edit",
                &[
                    Command::Undo,
                    Command::Redo,
                    Command::Cut,
                    Command::Copy,
                    Command::Paste,
                    Command::SelectAll,
                    Command::Palette,
                ][..],
            ),
            (
                "Format",
                &[
                    Command::Bold,
                    Command::Italic,
                    Command::Paragraph,
                    Command::Heading1,
                    Command::Heading2,
                    Command::Heading3,
                    Command::Bullet,
                    Command::Numbered,
                ][..],
            ),
            (
                "View",
                &[
                    Command::Write,
                    Command::Source,
                    Command::Preview,
                    Command::Contents,
                    Command::Refresh,
                    Command::ZoomIn,
                    Command::ZoomOut,
                    Command::ActualSize,
                ][..],
            ),
        ] {
            let submenu = Submenu::new(title, true);
            for &command in commands {
                let entry = item(command);
                submenu.append(&entry)?;
                items.push((command, entry, true));
            }
            menu.append(&submenu)?;
        }
        let window = Submenu::with_items(
            "Window",
            true,
            &[
                &PredefinedMenuItem::minimize(None),
                &PredefinedMenuItem::zoom(None),
            ],
        )?;
        menu.append(&window)?;
        window.set_as_windows_menu_for_nsapp();
        let help = Submenu::new("Help", true);
        let tutorial = item(Command::Tutorial);
        help.append(&tutorial)?;
        items.push((Command::Tutorial, tutorial, true));
        menu.append(&help)?;
        help.set_as_help_menu_for_nsapp();
        menu.init_for_nsapp();
        let (tx, rx) = mpsc::channel();
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            if let Some(&command) = Command::ALL.iter().find(|c| c.label() == event.id.0) {
                let _ = tx.send(command);
                ctx.request_repaint();
            }
        }));
        Ok(Self {
            _menu: menu,
            rx,
            items,
        })
    }
    pub fn sync(&mut self, enabled: impl Fn(Command) -> bool) {
        for (command, item, was_enabled) in &mut self.items {
            let next = enabled(*command);
            if next != *was_enabled {
                item.set_enabled(next);
                *was_enabled = next;
            }
        }
    }
}
fn item(command: Command) -> MenuItem {
    use Command::*;
    let shortcut = match command {
        New => Some((Modifiers::META, Code::KeyN)),
        Open => Some((Modifiers::META, Code::KeyO)),
        Save => Some((Modifiers::META, Code::KeyS)),
        SaveAs => Some((Modifiers::META | Modifiers::SHIFT, Code::KeyS)),
        Export => Some((Modifiers::META | Modifiers::SHIFT, Code::KeyE)),
        Close => Some((Modifiers::META, Code::KeyW)),
        Quit => Some((Modifiers::META, Code::KeyQ)),
        Undo => Some((Modifiers::META, Code::KeyZ)),
        Redo => Some((Modifiers::META | Modifiers::SHIFT, Code::KeyZ)),
        Cut => Some((Modifiers::META, Code::KeyX)),
        Copy => Some((Modifiers::META, Code::KeyC)),
        Paste => Some((Modifiers::META, Code::KeyV)),
        SelectAll => Some((Modifiers::META, Code::KeyA)),
        Bold => Some((Modifiers::META, Code::KeyB)),
        Italic => Some((Modifiers::META, Code::KeyI)),
        Write => Some((Modifiers::META, Code::Digit1)),
        Source => Some((Modifiers::META, Code::Digit2)),
        Preview => Some((Modifiers::META, Code::Digit3)),
        Contents => Some((Modifiers::META | Modifiers::SHIFT, Code::KeyL)),
        Refresh => Some((Modifiers::META, Code::KeyR)),
        ZoomIn => Some((Modifiers::META, Code::Equal)),
        ZoomOut => Some((Modifiers::META, Code::Minus)),
        ActualSize => Some((Modifiers::META, Code::Digit0)),
        Palette => Some((Modifiers::META, Code::KeyK)),
        _ => None,
    };
    MenuItem::with_id(
        command.label(),
        command.label(),
        true,
        shortcut.map(|(modifiers, key)| Accelerator::new(modifiers, key)),
    )
}
