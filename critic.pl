#!/usr/bin/env perl
# critic, in the treehouse out back. The runtime is lib/Bot/HouseBot.pm; per-bot settings are in
# lib/Bot/Profiles.pm. Persona and mission text come from critic.persona.txt
# and critic.mission.txt next to this script. Environment: see Bot::HouseBot.

use strict;
use warnings;
use lib 'lib';

BEGIN {
  $Bot::HouseBot::PROFILE     = 'critic';
  $Bot::HouseBot::SCRIPT_FILE = __FILE__;
}
use Bot::HouseBot;

Bot::HouseBot->run unless caller;
