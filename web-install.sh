#!/usr/bin/env bash
set -euo pipefail

# Doey — Web Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/FRIKKern/doey/main/web-install.sh | bash

REPO_URL="https://github.com/FRIKKern/doey.git"
CLONE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/doey-install.XXXXXX")
trap 'rm -rf "$CLONE_DIR"' EXIT

cat << 'DOG'

            .
           ...      :-=++++==--:
               .-***=-:.   ..:=+#%*:
    .     :=----=.               .=%*=:
    ..   -=-                     .::. :#*:
      .+=    := .-+**+:        :#@%%@%- :*%=
      *+.    @.*@**@@@@#.      %@=  *@@= :*=
    :*:     .@=@=  *@@@@%      #@%+#@%#@  :-+
   .%++      #*@@#%@@#%@@      :@@@@@*+@  :%#
    %#       ==%@@@@@=+@+       :*%@@@#: :=*
   .@--     -+=.+%@@@@*:            :.:--:-.
   .@%#    ##*  ...:.:                 +=
    .-@- .#*.   . ..                   :%
      :+++%.:       .=.                 #+
          =**        .*=                :@.
       .   .@:+.       +#:               =%
            :*:+:--.   =+%*.              *+
                .- :-=:-+:+%=              #:
                           .*%-            .%.
                             :%#:        ...-#
                               =%*.   =#@%@@@@*
                                 =%+.-@@#=%@@@@-
                                   -#*@@@@@@@@@.
                                     .=#@@@@%+.

   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
   Let Doey do it for you

  ======================================

DOG

if ! command -v git &>/dev/null; then
  echo "  ✗ git is required but not installed."
  echo "    Install: brew install git (macOS) | apt install git (Linux)"
  exit 1
fi

echo "  Cloning repository..."
if git clone --depth 1 "$REPO_URL" "$CLONE_DIR"; then
  echo "  ✓ Repository cloned"
else
  echo "  ✗ Failed to clone repository — check git and network access."
  exit 1
fi

echo ""
bash "$CLONE_DIR/install.sh"
