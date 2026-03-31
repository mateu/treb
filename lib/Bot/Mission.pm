package Bot::Mission;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(load_mission_for_script);

sub load_mission_for_script {
  my (%args) = @_;

  my $script_file = $args{script_file} or die 'load_mission_for_script requires script_file';
  my $mission_file = $args{mission_file} || do {
    my $path = $script_file;
    $path =~ s/\.pl$/.mission.txt/;
    $path;
  };

  open my $mf, '<', $mission_file or die "Unable to read mission file $mission_file: $!";
  my $mission = do { local $/; <$mf> };
  close $mf;

  my $base_persona_file = $args{base_persona_file} || do {
    my $path = $script_file;
    $path =~ s{[^/]+\.pl$}{base.persona.txt};
    $path;
  };
  my $bot_persona_file = $args{bot_persona_file} || do {
    my $path = $script_file;
    $path =~ s/\.pl$/.persona.txt/;
    $path;
  };

  if ($mission =~ /\{\{BASE_PERSONA\}\}/) {
    open my $bf, '<', $base_persona_file
      or die "Mission template references {{BASE_PERSONA}} but $base_persona_file is missing: $!";
    my $base_persona = do { local $/; <$bf> };
    close $bf;
    $mission =~ s/\{\{BASE_PERSONA\}\}/$base_persona/g;
  }

  if ($mission =~ /\{\{BOT_PERSONA\}\}/) {
    open my $pf, '<', $bot_persona_file
      or die "Mission template references {{BOT_PERSONA}} but $bot_persona_file is missing: $!";
    my $bot_persona = do { local $/; <$pf> };
    close $pf;
    $mission =~ s/\{\{BOT_PERSONA\}\}/$bot_persona/g;
  }

  my %mission_vars = (
    '{{NICK}}'     => $args{nick},
    '{{OWNER}}'    => $args{owner},
    '{{MODEL}}'    => $args{model},
    '{{PROVIDER}}' => $args{provider},
    '{{CHANNELS}}' => $args{channels},
    '{{MAX_LINE}}' => $args{max_line},
  );
  for my $k (keys %mission_vars) {
    my $v = defined $mission_vars{$k} ? $mission_vars{$k} : '';
    $mission =~ s/\Q$k\E/$v/g;
  }

  if (my $extra = $args{mission_extra}) {
    $mission .= "\n$extra\n";
  }

  return $mission;
}

1;
