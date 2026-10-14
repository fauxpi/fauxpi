//! Wayland protocol interface names, versions, opcodes, and constants.

pub const wl_display = struct {
    pub const name = "wl_display";
    pub const id: u32 = 1;
    pub const request = struct {
        pub const sync = 0;
        pub const get_registry = 1;
    };
    pub const event = struct {
        pub const @"error" = 0;
        pub const delete_id = 1;
    };
};

pub const wl_registry = struct {
    pub const name = "wl_registry";
    pub const request = struct {
        pub const bind = 0;
    };
    pub const event = struct {
        pub const global = 0;
        pub const global_remove = 1;
    };
};

pub const wl_callback = struct {
    pub const name = "wl_callback";
    pub const event = struct {
        pub const done = 0;
    };
};

pub const wl_compositor = struct {
    pub const name = "wl_compositor";
    pub const version = 6;
    pub const request = struct {
        pub const create_surface = 0;
        pub const create_region = 1;
    };
};

pub const wl_surface = struct {
    pub const name = "wl_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const attach = 1;
        pub const damage = 2;
        pub const frame = 3;
        pub const set_opaque_region = 4;
        pub const set_input_region = 5;
        pub const commit = 6;
        pub const set_buffer_transform = 7;
        pub const set_buffer_scale = 8;
        pub const damage_buffer = 9;
    };
    pub const event = struct {
        pub const enter = 0;
        pub const leave = 1;
        pub const preferred_buffer_scale = 2;
        pub const preferred_buffer_transform = 3;
    };
};

pub const wl_output = struct {
    pub const name = "wl_output";
    pub const version = 4;
    pub const request = struct {
        pub const release = 0;
    };
    pub const event = struct {
        pub const geometry = 0;
        pub const mode = 1;
        pub const done = 2;
        pub const scale = 3;
        pub const name = 4;
        pub const description = 5;
    };
};

pub const wl_buffer = struct {
    pub const name = "wl_buffer";
    pub const request = struct {
        pub const destroy = 0;
    };
    pub const event = struct {
        pub const release = 0;
    };
};

pub const wl_shm = struct {
    pub const name = "wl_shm";
    pub const version = 1;
    pub const request = struct {
        pub const create_pool = 0;
    };
    pub const event = struct {
        pub const format = 0;
    };
    pub const format = struct {
        pub const argb8888 = 0;
        pub const xrgb8888 = 1;
    };
};

pub const wl_shm_pool = struct {
    pub const name = "wl_shm_pool";
    pub const request = struct {
        pub const create_buffer = 0;
        pub const destroy = 1;
        pub const resize = 2;
    };
};

pub const xdg_wm_base = struct {
    pub const name = "xdg_wm_base";
    pub const version = 6;
    pub const request = struct {
        pub const destroy = 0;
        pub const create_positioner = 1;
        pub const get_xdg_surface = 2;
        pub const pong = 3;
    };
    pub const event = struct {
        pub const ping = 0;
    };
};

pub const xdg_surface = struct {
    pub const name = "xdg_surface";
    pub const request = struct {
        pub const destroy = 0;
        pub const get_toplevel = 1;
        pub const get_popup = 2;
        pub const set_window_geometry = 3;
        pub const ack_configure = 4;
    };
    pub const event = struct {
        pub const configure = 0;
    };
};

pub const xdg_toplevel = struct {
    pub const name = "xdg_toplevel";
    pub const request = struct {
        pub const destroy = 0;
        pub const set_parent = 1;
        pub const set_title = 2;
        pub const set_app_id = 3;
        pub const show_window_menu = 4;
        pub const move = 5;
        pub const resize = 6;
        pub const set_max_size = 7;
        pub const set_min_size = 8;
        pub const set_maximized = 9;
        pub const unset_maximized = 10;
        pub const set_fullscreen = 11;
        pub const unset_fullscreen = 12;
        pub const set_minimized = 13;
    };
    pub const event = struct {
        pub const configure = 0;
        pub const close = 1;
        pub const configure_bounds = 2;
        pub const wm_capabilities = 3;
    };
};

pub const wl_seat = struct {
    pub const name = "wl_seat";
    pub const version = 5;
    pub const request = struct {
        pub const get_pointer = 0;
        pub const get_keyboard = 1;
        pub const get_touch = 2;
        pub const release = 3;
    };
    pub const event = struct {
        pub const capabilities = 0;
        pub const name = 1;
    };
    pub const capability = struct {
        pub const pointer = 1;
        pub const keyboard = 2;
        pub const touch = 4;
    };
};

pub const wl_pointer = struct {
    pub const name = "wl_pointer";
    pub const request = struct {
        pub const set_cursor = 0;
        pub const release = 1;
    };
    pub const event = struct {
        pub const enter = 0;
        pub const leave = 1;
        pub const motion = 2;
        pub const button = 3;
        pub const axis = 4;
        pub const frame = 5;
        pub const axis_source = 6;
        pub const axis_stop = 7;
        pub const axis_discrete = 8;
    };
    pub const button_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
    pub const axis = struct {
        pub const vertical_scroll = 0;
        pub const horizontal_scroll = 1;
    };
};

pub const wl_keyboard = struct {
    pub const name = "wl_keyboard";
    pub const request = struct {
        pub const release = 0;
    };
    pub const event = struct {
        pub const keymap = 0;
        pub const enter = 1;
        pub const leave = 2;
        pub const key = 3;
        pub const modifiers = 4;
        pub const repeat_info = 5;
    };
    pub const key_state = struct {
        pub const released = 0;
        pub const pressed = 1;
    };
};

pub const input = struct {
    pub const btn_left = 0x110;
    pub const btn_right = 0x111;
    pub const btn_middle = 0x112;
};
