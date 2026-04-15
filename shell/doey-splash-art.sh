#!/usr/bin/env bash
# doey-splash-art.sh — Single source of truth for Doey ASCII art.
# Sourceable library, not standalone.
set -euo pipefail

# Source guard — prevent double-sourcing
[ "${__doey_splash_art_sourced:-}" = "1" ] && return 0
__doey_splash_art_sourced=1

# ── DOEY block-letter ASCII art ─────────────────────────────────────
# Raw text only — callers add their own color escapes.
DOEY_SPLASH_ART="$(cat << 'EOF'
   ██████╗  ██████╗ ███████╗██╗   ██╗
   ██╔══██╗██╔═══██╗██╔════╝╚██╗ ██╔╝
   ██║  ██║██║   ██║█████╗   ╚████╔╝
   ██║  ██║██║   ██║██╔══╝    ╚██╔╝
   ██████╔╝╚██████╔╝███████╗   ██║
   ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝
EOF
)"

# ── Dog ASCII art ───────────────────────────────────────────────────
# Raw text only — callers add their own color escapes.
DOEY_DOG_ART="$(cat << 'EOF'
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
EOF
)"
