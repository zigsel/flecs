//! Typed accessors for flecs' builtin unit entities, so you reference units as
//! `flecs.units.MetersPerSecond` instead of a stringly-typed path. Each returns
//! the unit's entity id (valid once the units module is imported - reflection
//! imports it for you when a component declares `flecs_units`).
//!
//! Declare units on a component and they're applied during `world.reflect`:
//!
//!     const Velocity = struct {
//!         x: f32, y: f32,
//!         pub const flecs_units = .{ .x = flecs.units.MetersPerSecond,
//!                                    .y = flecs.units.MetersPerSecond };
//!     };

const c = @import("c");
const Id = @import("meta.zig").Id;

// length
pub fn Meters() Id {
    return c.EcsMeters;
}
pub fn KiloMeters() Id {
    return c.EcsKiloMeters;
}
pub fn MilliMeters() Id {
    return c.EcsMilliMeters;
}
pub fn Pixels() Id {
    return c.EcsPixels;
}
// time
pub fn Seconds() Id {
    return c.EcsSeconds;
}
pub fn MilliSeconds() Id {
    return c.EcsMilliSeconds;
}
pub fn Minutes() Id {
    return c.EcsMinutes;
}
pub fn Hours() Id {
    return c.EcsHours;
}
pub fn Days() Id {
    return c.EcsDays;
}
// speed
pub fn MetersPerSecond() Id {
    return c.EcsMetersPerSecond;
}
// mass
pub fn Grams() Id {
    return c.EcsGrams;
}
pub fn KiloGrams() Id {
    return c.EcsKiloGrams;
}
// temperature
pub fn Celsius() Id {
    return c.EcsCelsius;
}
pub fn Kelvin() Id {
    return c.EcsKelvin;
}
pub fn Fahrenheit() Id {
    return c.EcsFahrenheit;
}
// angle
pub fn Degrees() Id {
    return c.EcsDegrees;
}
pub fn Radians() Id {
    return c.EcsRadians;
}
// frequency / force / pressure
pub fn Hertz() Id {
    return c.EcsHertz;
}
pub fn KiloHertz() Id {
    return c.EcsKiloHertz;
}
pub fn Newton() Id {
    return c.EcsNewton;
}
pub fn Pascal() Id {
    return c.EcsPascal;
}
// misc
pub fn Percentage() Id {
    return c.EcsPercentage;
}
pub fn Bytes() Id {
    return c.EcsBytes;
}
pub fn KiloBytes() Id {
    return c.EcsKiloBytes;
}
pub fn MegaBytes() Id {
    return c.EcsMegaBytes;
}
