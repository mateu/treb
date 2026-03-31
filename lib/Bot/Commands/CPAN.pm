package Bot::Commands::CPAN;

use strict;
use warnings;

use Exporter 'import';
use JSON::PP ();
use URI::Escape ();

our @EXPORT_OK = qw(
  _metacpan_get_json
  _metacpan_get_text
  _extract_pod_section
  _format_cpan_module_result
  _format_cpan_describe_result
  _format_cpan_author_result
  _format_cpan_recent_results
  _cpan_lookup
  _summarize_special_url
  _summarize_metacpan_pod
);

sub _metacpan_get_json {
  my ($self, $url) = @_;
  return undef unless defined $url && length $url;

  my @cmd = (
    'curl', '-fsS',
    '--connect-timeout', '10',
    '--max-time', '20',
    '-A', 'treb-metacpan/1.0',
    $url,
  );

  my $raw = eval {
    local $ENV{LC_ALL} = 'C';
    open my $fh, '-|', @cmd or die "curl failed: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    $body;
  };

  return undef if $@ || !defined $raw || $raw !~ /\S/;
  my $data = eval { JSON::PP::decode_json($raw) };
  return undef if $@ || ref($data) ne 'HASH';
  return $data;
}

sub _metacpan_get_text {
  my ($self, $url) = @_;
  return undef unless defined $url && length $url;

  my @cmd = (
    'curl', '-fsS',
    '--connect-timeout', '10',
    '--max-time', '20',
    '-A', 'treb-metacpan/1.0',
    $url,
  );

  my $raw = eval {
    local $ENV{LC_ALL} = 'C';
    open my $fh, '-|', @cmd or die "curl failed: $!";
    local $/;
    my $body = <$fh>;
    close $fh;
    $body;
  };

  return undef if $@ || !defined $raw || $raw !~ /\S/;
  return $raw;
}

sub _extract_pod_section {
  my ($self, $pod, $section_name) = @_;
  return undef unless defined($pod) && $pod =~ /\S/;
  return undef unless defined($section_name) && $section_name =~ /\S/;

  my @lines = split /\n/, $pod;
  my $want = lc $section_name;
  my $in = 0;
  my @buf;

  for my $line (@lines) {
    if (!$in) {
      if ($line =~ /^=head1\s+(.+)\s*$/) {
        my $name = lc $1;
        $name =~ s/^\s+|\s+$//g;
        $in = 1 if $name eq $want;
      }
      next;
    }

    last if $line =~ /^=head\d+\s+/;
    push @buf, $line;
  }

  my $text = join("\n", @buf);
  return undef unless $text =~ /\S/;

  $text =~ s/^=over\b.*?$//mg;
  $text =~ s/^=back\b.*?$//mg;
  $text =~ s/^=item\b\s*//mg;
  $text =~ s/L<([^>|]+)\|([^>]+)>/$2/g;
  $text =~ s/L<([^>]+)>/$1/g;
  $text =~ s/C<([^>]+)>/$1/g;
  $text =~ s/B<([^>]+)>/$1/g;
  $text =~ s/I<([^>]+)>/$1/g;
  $text =~ s/F<([^>]+)>/$1/g;
  $text =~ s/S<([^>]+)>/$1/g;
  $text =~ s/E<mdash>/--/g;
  $text =~ s/E<ndash>/-/g;
  $text =~ s/E<lt>/</g;
  $text =~ s/E<gt>/>/g;
  $text =~ s/E<sol>/\//g;
  $text =~ s/E<verbar>/|/g;
  $text =~ s/E<amp>/&/g;
  $text =~ s/E<quot>/"/g;
  $text =~ s/E<apos>/'/g;
  $text =~ s/E<[^>]+>//g;
  $text = $self->_clean_text_for_irc($text);
  my @paras = grep { /\S/ } split /\n\n+/, $text;
  @paras = map {
    my $p = $_;
    $p =~ s/\n+/ /g;
    $p =~ s/[ ]{2,}/ /g;
    $p =~ s/^\s+|\s+$//g;
    $p;
  } @paras;
  $text = join("\n\n", grep { defined && /\S/ } @paras);
  $text =~ s/^\s+|\s+$//g;
  return undef unless $text =~ /\S/;
  return $text;
}

sub _format_cpan_module_result {
  my ($self, $query, $data) = @_;
  return "MetaCPAN module not found: $query" unless ref($data) eq 'HASH';

  my $name = $data->{documentation}
    || (ref($data->{module}) eq 'ARRAY' && @{$data->{module}} ? $data->{module}[0]{name} : undef)
    || $data->{name}
    || $query;
  my $dist = $data->{distribution} || '?';
  my $author = $data->{author} || '?';
  my $abstract = $self->_clean_text_for_irc($data->{abstract} || 'No abstract available.');
  my $doc_url = 'https://metacpan.org/pod/' . URI::Escape::uri_escape_utf8($name);
  return "$name - $abstract Dist: $dist. Author: $author. Docs: $doc_url";
}

sub _format_cpan_describe_result {
  my ($self, $query, $data) = @_;
  return "MetaCPAN module not found: $query" unless ref($data) eq 'HASH';

  my $name = $data->{documentation}
    || (ref($data->{module}) eq 'ARRAY' && @{$data->{module}} ? $data->{module}[0]{name} : undef)
    || $data->{name}
    || $query;

  my $pod_url = 'https://fastapi.metacpan.org/v1/pod/' . URI::Escape::uri_escape_utf8($name) . '?content-type=text/x-pod';
  my $pod = $self->_metacpan_get_text($pod_url);
  my $desc = $self->_extract_pod_section($pod, 'DESCRIPTION');
  return $desc if defined $desc && $desc =~ /\S/;

  $desc = $self->_clean_text_for_irc($data->{description} || $data->{abstract} || 'No description available.');
  return $desc;
}

sub _format_cpan_author_result {
  my ($self, $query, $data) = @_;
  return "MetaCPAN author not found: $query" unless ref($data) eq 'HASH';

  my $pauseid = $data->{pauseid} || $query;
  my $name = $self->_clean_text_for_irc($data->{name} || 'Unknown author');
  return "$pauseid - $name - https://metacpan.org/author/" . URI::Escape::uri_escape_utf8($pauseid);
}

sub _format_cpan_recent_results {
  my ($self, $data, $limit) = @_;
  $limit //= 3;
  $limit = 1 if $limit < 1;
  $limit = 7 if $limit > 7;

  return 'No MetaCPAN recent releases found.' unless ref($data) eq 'HASH';
  my $hits = $data->{hits} && $data->{hits}{hits};
  return 'No MetaCPAN recent releases found.' unless ref($hits) eq 'ARRAY' && @$hits;

  my @out;
  my %seen;
  my $i = 0;
  for my $hit (@$hits) {
    next unless ref($hit) eq 'HASH';
    my $src = $hit->{_source} || {};
    my $dist = $src->{distribution} || $src->{name} || 'unknown';
    next if $seen{$dist}++;
    my $author = $src->{author} || '?';
    my $date = $src->{date} || '?';
    my $version = defined $src->{version} && length $src->{version} ? ' ' . $src->{version} : '';
    my $url = 'https://metacpan.org/release/' . URI::Escape::uri_escape_utf8($dist);
    push @out, sprintf('%d. %s%s (%s, %s) %s', ++$i, $dist, $version, $author, $date, $url);
    last if @out >= $limit;
  }
  return 'No MetaCPAN recent releases found.' unless @out;
  return "MetaCPAN recent:\n" . join("\n", @out);
}

sub _cpan_lookup {
  my ($self, $mode, $query) = @_;
  $mode //= '';
  $query //= '';
  $mode =~ s/^\s+|\s+$//g;
  $query =~ s/^\s+|\s+$//g;
  return 'Usage: :cpan <name> | :cpan module <name> | :cpan describe <name> | :cpan author <query> | :cpan recent [count]' unless length($mode) && length($query);

  if (lc($mode) eq 'module') {
    my $url = 'https://fastapi.metacpan.org/v1/module/' . URI::Escape::uri_escape_utf8($query);
    my $data = $self->_metacpan_get_json($url);
    return $self->_format_cpan_module_result($query, $data);
  }

  if (lc($mode) eq 'describe') {
    my $url = 'https://fastapi.metacpan.org/v1/module/' . URI::Escape::uri_escape_utf8($query);
    my $data = $self->_metacpan_get_json($url);
    return $self->_format_cpan_describe_result($query, $data);
  }

  if (lc($mode) eq 'author') {
    my $exact = uc $query;
    if ($exact =~ /^[A-Z0-9-]+$/) {
      my $exact_url = 'https://fastapi.metacpan.org/v1/author/' . URI::Escape::uri_escape_utf8($exact);
      my $exact_data = $self->_metacpan_get_json($exact_url);
      return $self->_format_cpan_author_result($query, $exact_data) if $exact_data;
    }
    my $url = 'https://fastapi.metacpan.org/v1/author/_search?q=' . URI::Escape::uri_escape_utf8($query) . '&size=1';
    my $data = $self->_metacpan_get_json($url);
    if (ref($data) eq 'HASH' && ref($data->{hits}{hits}) eq 'ARRAY' && @{$data->{hits}{hits}}) {
      my $src = $data->{hits}{hits}[0]{_source} || {};
      return $self->_format_cpan_author_result($query, $src);
    }
    return "MetaCPAN author not found: $query";
  }

  if (lc($mode) eq 'recent') {
    my $limit = 3;
    if ($query =~ /^\s*(\d+)\s*$/) {
      $limit = $1;
    }
    $limit = 1 if $limit < 1;
    $limit = 7 if $limit > 7;
    my $fetch = $limit * 3;
    $fetch = 9 if $fetch < 9;
    $fetch = 30 if $fetch > 30;
    my $url = 'https://fastapi.metacpan.org/v1/release/_search?q=status:latest&size=' . $fetch . '&sort=date:desc';
    my $data = $self->_metacpan_get_json($url);
    return $self->_format_cpan_recent_results($data, $limit);
  }

  return 'Usage: :cpan <name> | :cpan module <name> | :cpan describe <name> | :cpan author <query> | :cpan recent [count]';
}

sub _summarize_special_url {
  my ($self, $url) = @_;

  if ($url =~ m{^https?://metacpan\.org/pod/([^/?#]+)}i) {
    my $module = URI::Escape::uri_unescape($1);
    return $self->_summarize_metacpan_pod($module);
  }

  return;
}

sub _summarize_metacpan_pod {
  my ($self, $module) = @_;
  return 'MetaCPAN module URL is missing a module name.' unless defined($module) && $module =~ /\S/;

  my $url = 'https://fastapi.metacpan.org/v1/module/' . URI::Escape::uri_escape_utf8($module);
  my $data = $self->_metacpan_get_json($url);
  return "MetaCPAN module summary failed for: $module" unless ref($data) eq 'HASH';

  my $doc = $data->{documentation}
    || (ref($data->{module}) eq 'ARRAY' && @{$data->{module}} ? $data->{module}[0]{name} : undef)
    || $data->{name}
    || $module;
  my $pod_url = 'https://fastapi.metacpan.org/v1/pod/' . URI::Escape::uri_escape_utf8($doc) . '?content-type=text/x-pod';
  my $pod = $self->_metacpan_get_text($pod_url);
  my $name_text = $self->_extract_pod_section($pod, 'NAME');
  my $desc = $self->_extract_pod_section($pod, 'DESCRIPTION');

  $name_text = $data->{abstract} unless defined $name_text && $name_text =~ /\S/;
  $desc = $data->{description} || $data->{abstract} || 'No description available.' unless defined $desc && $desc =~ /\S/;

  $name_text = $self->_clean_text_for_irc($name_text) if defined $name_text;
  $desc = $self->_clean_text_for_irc($desc);
  $desc = substr($desc, 0, 420) . '...' if length($desc) > 420;
  my $doc_url = 'https://metacpan.org/pod/' . URI::Escape::uri_escape_utf8($doc);

  if (defined $name_text && length $name_text) {
    return "$name_text
$desc
Docs: $doc_url";
  }
  return "$doc
$desc
Docs: $doc_url";
}

1;
