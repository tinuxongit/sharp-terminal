//! The name Sharp shows to people, and the prefix of its Win32 window
//! classes so it never collides with an installed Ghostty build. Programs
//! inside the terminal still see Ghostty's TERM_PROGRAM and terminfo, so
//! their Ghostty support keeps working.
pub const name = "Sharp";
