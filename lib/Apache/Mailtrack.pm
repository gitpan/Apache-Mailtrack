package Apache::Mailtrack;

#
# $Id: Mailtrack.pm,v 1.1.1.1 2002/07/31 13:10:44 fhe Exp $
#

use 5.006;
use strict;
use warnings;

use Apache::Constants qw/OK REDIRECT/;
use Apache::Request;
use Data::Serializer;
use DBI qw/:sql_types/;

our $VERSION = '0.01';
our %config;

my $serializer;

sub handler
	{
	my $r		= Apache::Request->new(shift);
	my $userdata	= $r->param('userdata');
	my $target	= $r->param('target');
	my $internal;
	my $data;

	our %config;

	#
	# If we didn't get set up correctly, warn about this and throw a really ugly error.
	#
	foreach(qw/db_dsn db_user db_pass db_table/)
		{
		error($r, 'Apache::Mailtrack> Please configure me correctly (check my manpage).')
			unless $config{$_} = $r->dir_config($_);
		}

	#
	# Read out optional configuration settings or set defaults.
	#
	$config{'serializer'} = $r->dir_config('serializer') || 'Storable';
	$config{'secret'} = $r->dir_config('secret') if defined $r->dir_config('secret');
	$config{'path'} = $r->dir_config('path') || '/images';
	$config{'defaultfile'} = $r->dir_config('defaultfile') || 'mailtrack_default.jpg';
	$config{'db_target'} = $r->dir_config('db_target') if defined $r->dir_config('db_target');

	$serializer ||= Data::Serializer->new(
		serializer	=> $config{'serializer'},
		secret		=> $config{'secret'} || undef,
		);
	
	#
	# Redirect to the defaultfile if we didn't get the required parameters.
	#
	error($r, "Apache::Mailtrack> I didn't get the parameters I want - check your rewrite rule.")
		unless defined $userdata and defined $target;

	#
	# Deserialze userdata.
	#
	eval
		{
		$data = $serializer->deserialize($userdata);
		};
	
	#
	# If we couldn't deserialize the userdata, redirect to the defaultfile.
	#
	error($r, "Apache::Mailtrack> Couldn't deserialize the userdata - maybe you should check your secret?")
		if $@;

	#
	# Let's look, whether we got a URL as target...
	#
	if($target =~ m/^url\|(.*)/)
		{
		$data->{'target'} = $1 unless exists $data->{'target'};
		$target = 'http://' . $1;
		}
	#
	# or some file.
	#
	else
		{
		$target = $config{'path'} . '/' . $target;
		$internal = 1;
		}
	
	#
	# Log into DB.
	#
	eval
		{
		my $query;
		my $dbh;
		my $sth;

		#
		# If we should also log the target, add it to the data hash,
		#
		$data->{'target'} = $config{'target'} if exists $config{'target'};
		$query = sprintf('INSERT INTO %s (%s) VALUES (%s)',  $config{'db_table'},
				join(',', sort keys %$data), '?,' x scalar keys %$data);
		$query =~ s/,\)/\)/;

		$dbh = DBI->connect($config{'db_dsn'}, $config{'db_user'}, $config{'db_pass'},
			{ AutoCommit => 0, RaiseError => 1 });
		$sth = $dbh->prepare($query);

		$sth->execute(map { $data->{$_} } sort keys %$data);
		$sth->finish();
		$dbh->commit();
		$dbh->disconnect();
		};
	
	error($r, $@) if $@;

	#
	# If we serve a local resource, generate an internal redirect...
	#
	if(defined($internal))
		{
		$r->internal_redirect($target);
		OK;
		}
	#
	# If we should redirect to another URL, do so.
	#
	else
		{
		$r->headers_out->set(Location => $target);
		REDIRECT;
		}
	}


#
# Redirect to the defaultfile (used in case of emergency).
# Also warns about the possible reason for doing so.
#
sub error
	{
	my($r, $fatal) = @_;
	our %config;

	$r->warn($fatal);
	$r->internal_redirect($config{'path'} . '/' . $config{'defaultfile'});
	exit OK;
	}


1;
__END__

=head1 NAME

Apache::Mailtrack - keep track of views of HTML newsletters


=head1 SYNOPSIS

In your local httpd.conf:

  RewriteEngine On
  RewriteRule /Mailtrack/([^/]*)/(.*) /Mailtrack/?userdata=$1&target=$2 [P]

  <Location "/Mailtrack">
    PerlSetVar db_dsn      dbi:Pg:dbname=mydatabase
    PerlSetVar db_user     myuser
    PerlSetVar db_pass     mypass
    PerlSetVar db_table    mytable
    PerlSetVar db_target   mytarget

    PerlSetVar serializer  YAML
    PerlSetVar secret      "A top secret secret that is."

    PerlSetVar path        /images
    PerlSetVar defaultfile mod_newsletter_default.jpg

    SetHandler perl-script
    PerlHandler Apache::Mailtrack
  </Location>

In the body of the HTML newsletter:

  <img src="http://www.site.at/Mailtrack/[% userdata %]/some.gif">
  <a href="http://www.site.at/Mailtrack/[% userdata %]/url|use.perl.org">X</a>


=head1 DESCRIPTION

Apache::Mailtrack assists you in keeping track of the response generated by
an HTML newsletter (supposedly - or shall I say, hopefully - NOT SPAM), by
logging all views of the newsletter (via an embedded image, which is served
by this module) and logging all clicks on an URL (which gets also "served" by
this module via redirect) into a database capable of SQL (PostgreSQL, MySQL,
Oracle, and such).

The data to be logged must be provided in a serialized string, generated by
Data::Serializer, representing a hashref. Every entry of this hash is written
into the database, using the key as fieldname and writing the value into that
field.

The implementation of a script to generate such userdata and embed it into an
HTML mail is left as exercise to the reader.

The handler can be triggered either using an images embedded in the
newsletter, or by recipients clicking on a link that points to a location
handled by Apache::Mailtrack.

Using the file approach, you should get a log entry every time a recipient
views the mail in an HTML capable mail client. Example:

  <img src="http://www.site.at/Mailtrack/[% userdata %]/some.gif">

Using the link approach, you should get a log entry every time a recipient
clicks on a link pointing to an URL handled by Apache::Mailtrack. Example:

  <a href="http://www.site.at/Mailtrack/[% userdata %]/url|use.perl.org">X</a>

NOTE: the URL B<must not> contain the protocol (http://). In this release it is
only possible to link to HTTP resources.


=head1 INSTALLATION

Follow these steps to set up Apache::Mailtrack:

=over 4

=item *

Install Apache::Mailtrack and all needed modules.

=item *

Create the a table in the database you want to use for logging which fits your needs.

For example:

  CREATE TABLE log
    (
    subscriberid       INTEGER        NOT NULL,
    newsletterid       INTEGER        NOT NULL,
    target             TEXT,
    view               TIMESTAMP      NOT NULL DEFAULT NOW()
    );

=item *

Set up a location in your Apache config as shown in B<SYNOPSIS>.

=item *

Set up a rewrite rule to catch the request which should be handled by Apache::Mailtrack.

For example:

  RewriteEngine On
  RewriteRule /Mailtrack/(.*)/(.*) /Mailtrack/?userdata=$1&target=$2 [P]

Replace C<Mailtrack> with the location you use.

=item *

Restart Apache.

=back


=head1 CONFIGURATION

You have to set up at least the following variables in your httpd.conf
in the location you want to use Apache::Mailtrack using PerlSetVar:

=over 4

=item I<db_dsn>

complete DBI connect string

=item I<db_user>

database user

=item I<db_pass>

password to be used

=item I<db_table>

name of table we should log to

=back


Additionally you can define the following options:

=over 4

=item I<db_target>

name of the field in the defined table (see db_table) we should write the redirection target to [default: C<undef>]

=item I<serializer>

name of the serializer Data::Serializer should use [default: C<Storable>]

=item I<secret>

specify secret for use with encryption [default: C<undef>]

=item I<path>

default path to the served file [default: C</images>]

=item I<defaultfile>

file we should serve in case of emergency [default: C<mailtrack_default.jpg>]

=back


=head1 AUTHOR

Florian Helmberger <fh@laudatio.com>

=head1 SEE ALSO

L<mod_perl>, L<Apache::Request>, L<Apache::Constants>, L<Data::Serializer>, L<YAML>, L<DBI>

=cut
