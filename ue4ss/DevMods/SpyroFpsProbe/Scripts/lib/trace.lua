-- trace_<stamp>.csv: one row per sampled frame. "air" is the airborne segment id (0 on the ground),
-- "drift" the drift event id (0 when not drifting); "charge", "turn", "camlock" and "sc" are the ids
-- of the charge, turn, camera lock and super charge measurements in progress (0 outside them).
local paths = require("lib.paths")
local state = require("lib.state")
local util = require("lib.util")

local num, csvValue = util.num, util.csvValue

local trace = {}

local file = io.open(paths.trace, "w")
if file then
    file:write("time,dt,fps_cap,sim_step,air,drift,x,y,z,yaw,vx,vy,vz,input_x,input_y,accel_x,accel_y,move_mode,custom_mode,gravity_scale,floor_walkable,floor_dist,floor_nz,root_motion,pressed_jump,jump_hold_time,jump_max_hold_time,jump_force_remaining,"
        .. "charge,turn,camlock,charging,charge_tag,max_walk_speed,stick_x,stick_y,stick_rx,input_dt,vel_yaw,cam_yaw,cam_pitch,cam_offset,cam_rate,ctrl_yaw,follow_cam_yaw,cam_transitioning,ground_friction,mouse_raw,cam_ctr_interp,"
        .. "sc,sc_stage,max_accel,jump_z_velocity,falling_lateral_friction,cam_dist,cam_height,cam_fov,cam_rad_default\n")
end

function trace.writeRow(r)
    if not file then return end
    file:write(string.format(
        "%.5f,%.5f,%s,%.5f,%d,%d,%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%d,%d,%.4f,%s,%.3f,%.4f,%s,%s,%.4f,%.4f,%.4f,",
        r.time, r.dt, tostring(state.fpsCap or ""), num(r.simStep),
        state.segment and state.segment.id or 0, state.drift and state.drift.id or 0,
        -- num(): a property read during a pawn change once came back as light userdata.
        num(r.x), num(r.y), num(r.z), num(r.yaw), num(r.vx), num(r.vy), num(r.vz), num(r.inputX), num(r.inputY),
        num(r.accelX), num(r.accelY), num(r.mode), num(r.customMode), num(r.gravityScale), tostring(r.floorWalkable),
        num(r.floorDist), num(r.floorNz),
        tostring(r.rootMotion), tostring(r.pressedJump), num(r.jumpHoldTime), num(r.jumpMaxHoldTime), num(r.jumpForceRemaining)))
    file:write(string.format(
        "%s,%s,%s,%s,%s,%.1f,%.3f,%.3f,%.3f,%.5f,%.2f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f,%s,%.4f,%.4f,%.4f,",
        csvValue(state.charge and state.charge.id or 0), csvValue(state.turn and state.turn.id or 0),
        csvValue(state.camLock and state.camLock.id or 0), tostring(r.charging), csvValue(r.chargeTag),
        num(r.maxWalkSpeed), r.stickX, r.stickY, r.stickRX, r.inputDt, r.velYaw, r.camYaw, r.camPitch,
        r.camOffset, r.camRate, r.ctrlYaw, r.followCamYaw, csvValue(r.camTransitioning), num(r.groundFriction),
        r.mouseRaw, r.camCtrInterp))
    file:write(string.format("%d,%s,%.1f,%.1f,%.2f,%.2f,%.2f,%.3f,%.1f\n",
        state.superCharge and state.superCharge.id or 0, csvValue(r.superStage), num(r.maxAccel),
        num(r.jumpZVelocity), num(r.fallingLateralFriction), r.camDist, r.camHeight, r.camFov, r.camRadDefault))
end

-- Called when a measurement ends, so its rows are on disk next to its log line.
function trace.flush()
    if file then file:flush() end
end

return trace
