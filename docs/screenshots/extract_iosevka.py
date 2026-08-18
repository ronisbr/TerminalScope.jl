## Description #############################################################################
#
# Extract the Regular, Bold, Italic, and Bold Italic faces of the default Iosevka
# variant from a TrueType collection, so the screenshot rasterizer can load them:
#
#     python3 extract_iosevka.py <Iosevka.ttc> <output directory>
#
# Requires fontTools (https://github.com/fonttools/fonttools).
#
############################################################################################

import os
import sys

from fontTools.ttLib import TTCollection

src, out_dir = sys.argv[1], sys.argv[2]

wanted = {
    "Iosevka": "Iosevka-Regular.ttf",
    "Iosevka Bold": "Iosevka-Bold.ttf",
    "Iosevka Italic": "Iosevka-Italic.ttf",
    "Iosevka Bold Italic": "Iosevka-BoldItalic.ttf",
}

collection = TTCollection(src, lazy=True)

for font in collection.fonts:
    full_name = font["name"].getDebugName(4)
    target = wanted.pop(full_name, None)

    if target is not None:
        font.save(os.path.join(out_dir, target))
        print("extracted", target)

    if not wanted:
        break

if wanted:
    sys.exit("missing faces: " + ", ".join(sorted(wanted)))
