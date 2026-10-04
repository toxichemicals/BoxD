#pragma once
#include <algorithm>
#include <array>
#include <string_view>
#include <utility>
inline constexpr auto SHADERS = [](auto shaders) {
std::ranges::sort(shaders, {}, [](auto pair) { return pair.first; });
return shaders;
}(std::to_array<std::pair<std::string_view, std::string_view>>({
{"acrylicfinish.frag",
#include "./acrylicfinish.frag.inc"
},
{"aurorafinish.frag",
#include "./aurorafinish.frag.inc"
},
{"blur1.frag",
#include "./blur1.frag.inc"
},
{"blur1.glsl",
#include "./blur1.glsl.inc"
},
{"blur2.frag",
#include "./blur2.frag.inc"
},
{"blur2.glsl",
#include "./blur2.glsl.inc"
},
{"blurfinish.frag",
#include "./blurfinish.frag.inc"
},
{"blurFinish.glsl",
#include "./blurFinish.glsl.inc"
},
{"blurprepare.frag",
#include "./blurprepare.frag.inc"
},
{"blurprepare.glsl",
#include "./blurprepare.glsl.inc"
},
{"border.frag",
#include "./border.frag.inc"
},
{"border.glsl",
#include "./border.glsl.inc"
},
{"CM.glsl",
#include "./CM.glsl.inc"
},
{"cm_helpers.glsl",
#include "./cm_helpers.glsl.inc"
},
{"constants.h",
#include "./constants.h.inc"
},
{"defines.h",
#include "./defines.h.inc"
},
{"dropsfinish.frag",
#include "./dropsfinish.frag.inc"
},
{"ext.frag",
#include "./ext.frag.inc"
},
{"fluidjarfinish.frag",
#include "./fluidjarfinish.frag.inc"
},
{"fluidJar.glsl",
#include "./fluidJar.glsl.inc"
},
{"fluidjargraph.frag",
#include "./fluidjargraph.frag.inc"
},
{"fluidjarhistoryresample.frag",
#include "./fluidjarhistoryresample.frag.inc"
},
{"fluidjarinit.frag",
#include "./fluidjarinit.frag.inc"
},
{"fluidjarresample.frag",
#include "./fluidjarresample.frag.inc"
},
{"fluidjarstep.frag",
#include "./fluidjarstep.frag.inc"
},
{"fluidjartrack.frag",
#include "./fluidjartrack.frag.inc"
},
{"fluidjartrackingresample.frag",
#include "./fluidjartrackingresample.frag.inc"
},
{"fluidjarvisual.frag",
#include "./fluidjarvisual.frag.inc"
},
{"frostfinish.frag",
#include "./frostfinish.frag.inc"
},
{"gain.glsl",
#include "./gain.glsl.inc"
},
{"glassFinish.glsl",
#include "./glassFinish.glsl.inc"
},
{"glitch.frag",
#include "./glitch.frag.inc"
},
{"gradient.glsl",
#include "./gradient.glsl.inc"
},
{"hazefinish.frag",
#include "./hazefinish.frag.inc"
},
{"heatshimmerfinish.frag",
#include "./heatshimmerfinish.frag.inc"
},
{"inner_glow.frag",
#include "./inner_glow.frag.inc"
},
{"inner_glow.glsl",
#include "./inner_glow.glsl.inc"
},
{"motion_blur.glsl",
#include "./motion_blur.glsl.inc"
},
{"passthru.frag",
#include "./passthru.frag.inc"
},
{"prismfinish.frag",
#include "./prismfinish.frag.inc"
},
{"quad.frag",
#include "./quad.frag.inc"
},
{"rgbamatte.frag",
#include "./rgbamatte.frag.inc"
},
{"ripplefinish.frag",
#include "./ripplefinish.frag.inc"
},
{"rounding.glsl",
#include "./rounding.glsl.inc"
},
{"shadow.frag",
#include "./shadow.frag.inc"
},
{"shadow.glsl",
#include "./shadow.glsl.inc"
},
{"surface.frag",
#include "./surface.frag.inc"
},
{"tex300.vert",
#include "./tex300.vert.inc"
},
{"tex320.vert",
#include "./tex320.vert.inc"
},
{"tonemap.glsl",
#include "./tonemap.glsl.inc"
},
{"waterfinish.frag",
#include "./waterfinish.frag.inc"
},
{"waterstep.frag",
#include "./waterstep.frag.inc"
},
}));
