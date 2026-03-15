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

# Clone the repo
echo "  Cloning repository..."
if git clone --depth 1 "$REPO_URL" "$CLONE_DIR"; then
  echo "  ✓ Repository cloned"
else
  echo "  ✗ Failed to clone repository"
  echo "    Make sure git is installed and you have network access."
  exit 1
fi

echo ""

# Run the real installer
bash "$CLONE_DIR/install.sh"
