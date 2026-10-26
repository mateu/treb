#!/usr/bin/env perl
# Treb, in the attic. The runtime is lib/Bot/HouseBot.pm; per-bot settings are in
# lib/Bot/Profiles.pm. Persona and mission text come from treb.persona.txt
# and treb.mission.txt next to this script. Environment: see Bot::HouseBot.

use strict;
use warnings;
use lib 'lib';

BEGIN {
  $Bot::HouseBot::PROFILE     = 'treb';
  $Bot::HouseBot::SCRIPT_FILE = __FILE__;
}
use Bot::HouseBot;

Bot::HouseBot->run unless caller;
