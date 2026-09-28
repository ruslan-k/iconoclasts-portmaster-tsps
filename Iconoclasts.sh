#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt

[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"

get_controls

GAMEDIR="/$directory/ports/iconoclasts"
> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1
cd "$GAMEDIR" || { echo "Game directory missing: $GAMEDIR"; exit 1; }

# gl4es
if [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
  source "${controlfolder}/libgl_${CFW_NAME}.txt"
else
  source "${controlfolder}/libgl_default.txt"
fi

if [ "$LIBGL_FB" != "" ]; then
    export SDL_VIDEO_GL_DRIVER="$GAMEDIR/gl4es/libGL.so.1"
    export SDL_VIDEO_EGL_DRIVER="$GAMEDIR/gl4es/libEGL.so.1"
fi

cd $GAMEDIR/gamedata

export LIBGL_SKIPTEXCOPIES=1
export BOX64_ALLOWMISSINGLIBS=1
export SDL_DYNAMIC_API="libSDL2-2.0.so.0"
export BOX64_LD_PRELOAD="$GAMEDIR/libaa_preload.so"

export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$GAMEDIR/box64/native":"/usr/lib/arm-linux-aarch64/":"/usr/lib":"/usr/config/emuelec/lib"
export BOX64_LD_LIBRARY_PATH="$GAMEDIR/box64/lib":"$GAMEDIR/gamedata/bin64"

if [ -f "$GAMEDIR/settings.txt" ]; then
    source "$GAMEDIR/settings.txt"
fi

export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

# load user settings
export AA_HOOKING_CONFIG="$GAMEDIR/aa_hooking.json"

$ESUDO chmod 666 /dev/tty0
$ESUDO chmod 666 /dev/tty1
printf "\033c" > /dev/tty0

if [ ! -f 'bin64/Chowdren' ]; then
    # No game found, check for installers...
    for installer in iconoclasts_*.sh; do break; done;
    if [[ -z "$installer" ]] || [[ "$installer" == "iconoclasts_*.sh" ]]; then
        pm_message "No data, no installer... nothing to do :("
        exit -1
    fi

    pm_message "Installing from $installer..."

    # extract the installer, but make sure we got the Chowdren binary present!
    python3 ../extract.py "$installer" "data/noarch/game/bin64/Chowdren"
    if [ $? != 0 ]; then
		rm -f bin32/Chowdren
        pm_message "Install failed..."
        sleep 5
        exit -1
    fi
fi

if [ ! -f 'data/music/62SYS_title_B.dat' ]; then
	echo " .########.########..########...#######..########. "
	echo " .##.......##.....##.##.....##.##.....##.##.....## "
	echo " .##.......##.....##.##.....##.##.....##.##.....## "
	echo " .######...########..########..##.....##.########. "
	echo " .##.......##...##...##...##...##.....##.##...##.. "
	echo " .##.......##....##..##....##..##.....##.##....##. "
	echo " .########.##.....##.##.....##..#######..##.....## "
	echo " >> YOU ARE MISSING MUSIC DATA!!! <<"
	echo " >> MUSIC PLAYBACK WILL NOT WORK! <<"
	echo "Install the game and copy 'data/music' to 'gamedata/data/music'"
    pm_message "Music data missing! See log for details."
fi

# Set executable permissions for sdcards using ext2 or similar.
chmod +x "$GAMEDIR/box64/box64"
chmod +x "$GAMEDIR/gamedata/bin64/Chowdren"

$GPTOKEYB "Chowdren" -c "$GAMEDIR/iconoclasts.gptk" &
pm_platform_helper "$GAMEDIR/box64/box64"
$GAMEDIR/box64/box64 bin64/Chowdren

pm_finish
