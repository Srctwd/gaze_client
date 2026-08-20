cmake_minimum_required(VERSION 3.15)
project(stone_gaze)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SERVER_SOURCES
    src/console.cpp
    src/scmath.cpp
    src/systems/world.cpp
    src/systems/spawn.cpp
    src/systems/engine.cpp
    src/systems/physics.cpp
    src/systems/projectile.cpp
    src/systems/action.cpp
    src/systems/combat.cpp
    src/systems/regen.cpp
    src/systems/threat.cpp
    src/systems/ai.cpp
    src/systems/aoi.cpp
    src/systems/equip_sync.cpp
    src/systems/floor_item_sync.cpp
    src/systems/talent_sync.cpp
    src/systems/water.cpp
    src/systems/object_types.cpp
    src/systems/talents.cpp
    src/systems/item_types.cpp
    src/systems/monster_types.cpp
    src/systems/loot.cpp
    src/network/network.cpp
    src/network/auth.cpp
    src/network/sessions.cpp
)

set_source_files_properties(src/network/network.cpp PROPERTIES
    COMPILE_OPTIONS "-Wno-deprecated-enum-enum-conversion"
)

add_executable(server server.cpp ${SERVER_SOURCES})

target_link_libraries(server PRIVATE pthread pq)
target_compile_features(server PRIVATE cxx_std_20)
target_include_directories(server PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/systems
    ${CMAKE_SOURCE_DIR}/src/network
    ${CMAKE_SOURCE_DIR}/vendored/entt/single_include
    ${CMAKE_SOURCE_DIR}/vendored/
    /usr/include/postgresql
)
