#pragma once

#include "../config/ConfigValue.hpp"
#include <algorithm>
#include <hyprutils/math/Vector2D.hpp>

namespace CanvasProjection {
    inline bool enabled() {
        static auto value = CConfigValue<Config::INTEGER>("experimental:canvas_lens");
        return *value;
    }

    inline float strength() {
        static auto value = CConfigValue<Config::FLOAT>("experimental:canvas_lens_strength");
        return *value;
    }

    inline float edgeScale() {
        static auto value = CConfigValue<Config::FLOAT>("experimental:canvas_lens_edge_scale");
        return *value;
    }

    inline Vector2D sourcePoint(const Vector2D& point, const Vector2D& size, float amount) {
        if (amount == 0.F || !enabled())
            return point;
        const auto centered = point / size * 2.0 - Vector2D{1.0, 1.0};
        const auto radius2  = centered.x * centered.x + centered.y * centered.y;
        return (centered * ((1.0 + strength() * amount * radius2) / (1.0 + (edgeScale() - 1.0) * amount)) + Vector2D{1.0, 1.0}) * 0.5 * size;
    }
}
