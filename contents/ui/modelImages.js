/**
 * Antiphase — shared product-render lookup
 *
 * Imported as `import "modelImages.js" as ModelImages` by main.qml,
 * CompactRepresentation.qml and FullRepresentation.qml so the model ->
 * bundled webp table lives once (.pragma library makes it a single shared
 * instance). Relative URLs returned here resolve against the *calling*
 * component, which all live in contents/ui/.
 */

.pragma library

// Models with a bundled product render in images/.
var modelImages = ["wh-1000xm6", "wh-1000xm5", "wh-1000xm4",
                   "wf-1000xm6", "wf-1000xm5", "wh-ch720n"]

// Table key matching a device name ("WH-1000XM6"), or "" when unknown.
function imageKeyFor(name) {
    var key = String(name).toLowerCase()
    for (var i = 0; i < modelImages.length; i++) {
        if (key.indexOf(modelImages[i]) !== -1)
            return modelImages[i]
    }
    return ""
}

// Relative URL of the render, or "" when the model has none.
function imageSourceFor(name) {
    var key = imageKeyFor(name)
    return key === "" ? "" : "images/" + key + ".webp"
}
