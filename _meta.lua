local _ = require("gettext")
return {
    name = "eraser",
    fullname = _("Eraser"),
    description = _([[Delete highlights by swiping over them with the Eraser button held. Works like a real eraser - no confirmations, just instant deletion. Supports devices with a hardware eraser button (currently tested on Kobo devices).]]),
}
