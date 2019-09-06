package Koha::Plugin::Com::PTFSEurope::AvailabilityEds::Api;

 # This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use JSON qw( decode_json );
use MIME::Base64 qw( decode_base64 );
use URI::Escape qw ( uri_unescape );
use POSIX qw ( floor );
use LWP::UserAgent;
use HTTP::Request::Common;

use Mojo::Base 'Mojolicious::Controller';
use Koha::Database;
use Koha::Plugin::Com::PTFSEurope::AvailabilityEds;

sub search {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $base_url = "https://eds-api.ebscohost.com/";

    my $start = $c->validation->param('start') || 0;
    my $length = $c->validation->param('length') || 20;

    # Check we've got a userid and password specified in the config,
    # if not, we're using IP authentication
    my $plugin = Koha::Plugin::Com::PTFSEurope::AvailabilityEds->new();
    my $config = decode_json($plugin->retrieve_data('avail_config') || '{}');
    my $userid = $config->{ill_avail_eds_userid};
    my $password = $config->{ill_avail_eds_password};

    # Map from our property names to EDS search fieldCodes,
    # We create the mapping "backwards" so we can express that, for any
    # given EDS fieldCode, these are the ILL properties that could fulfil
    # that, in order of preference (most specific to least specific)
    my %map = (
        TI => [ 'article_title', 'chapter', 'title' ],
        AU => [ 'article_author', 'chapter_author', 'author' ],
        IB => [ 'isbn' ],
        IS => [ 'issn' ]
    );

    # Gather together what we've been passed
    my $metadata = $c->validation->param('metadata') || '';
    $metadata = decode_json(decode_base64(uri_unescape($metadata)));
    # Try and compile a search parameter list
    my %params = ();
    # Iterate each EDS fieldCode
    foreach my $fieldcode(keys %map) {
        # Iterate over the ILL properties related to this fieldCode
        # They are in preference order, so we end when we find a
        # populated one
        foreach my $prop (@{$map{$fieldcode}}) {
            my $this_prop = $metadata->{$prop};
            if ($this_prop && length $this_prop > 0) {
                $params{$fieldcode} = $this_prop;
                last;
            }
        }
    }

    # Bail out if we have nothing to search with
    if (!keys %params) {
        return_error($c, 400, 'No searchable metadata found');
    }

    # We should be OK to search, so let's start the process
    # How we do this depends on our authentication method, if we have
    # a userid and password specified in the config, we use those
    my $url;
    my $body;
    if ($userid && length $userid > 0 && $password && length $password > 0) {
        $url = 'authservice/rest/uidauth';
$body = <<"__BODY__";
        <UIDAuthRequestMessage xmlns="http://www.ebscohost.com/services/public/AuthService/Response/2012/06/01">
            <UserId>$userid</UserId>
            <Password>$password</Password>
        </UIDAuthRequestMessage>
__BODY__
    } else {
        $url = 'authservice/rest/ipauth';
    }
    my @auth_headers = (
        'Accept'       => 'application/json',
        'Content-type' => 'text/xml'
    );

    my $ua = LWP::UserAgent->new;
    my $auth_response = $ua->request(
        POST "${base_url}${url}",
        @auth_headers,
        Content => $body
    );

    my $auth_body = parse_response(
        $auth_response,
        { c => $c, err_code => 500, error => 'Unable to authenticate to EDS'}
    );

    if (!exists $auth_body->{AuthToken}) {
        return_error(
            $c,
            500,
            'Unable to authenticate to EDS: ' . $auth_response->decoded_content
        );
    }

    my $auth_token = $auth_body->{AuthToken};

    # Now we have an auth token, we can get a session token
    my @session_headers = (
        'Accept'                => 'application/json',
        'Content-type'          => 'application/json',
        'x-authenticationToken' => $auth_token
    );

    my $session_response = $ua->request(
        GET "${base_url}edsapi/rest/createsession?profile=edsapi",
        @session_headers
    );

    my $session_body = parse_response(
        $session_response,
        { c => $c, err_code => 500, error => 'Unable to get session token'}
    );

    if (!exists $session_body->{SessionToken}) {
        return_error(
            $c,
            500,
            'Unable to get session token: ' . $session_response->decoded_content
        );
    }

    my $session_token = $session_body->{SessionToken};

    # So now we have a session token, we can actually do some searching
    #
    # We have a preference as to what search parameters we should use,
    # if we have an ISBN or ISSN, we just want to use those, otherwise
    # we should use everything
    my @search_params = ();
    if ($params{IB}) {
        push @search_params, prep_param('IB', $params{IB});
    } elsif ($params{IS}) {
        push @search_params, prep_param('IS', $params{IS});
    } else {
        foreach my $p(keys %params) {
            push @search_params, prep_param($p, $params{$p});
        }
    }
    if (@search_params == 0) {
        return_error(
            $c,
            400,
            'Unable to form search query with supplied metadata'
        );
    }

    my $search_string = join('&', @search_params);

    my $query = "query=$search_string&includefacets=n";

    my @search_headers = (
        'Accept' => 'application/json',
        'x-sessionToken' => $session_token
    );

    # Calculate which page of result we're requesting
    my $page = floor($start / $length) + 1;
    my $search_response = $ua->request(
        GET "${base_url}edsapi/rest/Search?resultsperpage=$length&pagenumber=$page&query=$query",
        @search_headers
    );

    my $search_body = parse_response(
        $search_response,
        { c => $c, err_code => 500, error => 'Unable to get search results'}
    );

    my $out = prep_response($search_body);
    my $stats = prep_stats($search_body);

    return $c->render(
        status => 200,
        openapi => {
            start => $start,
            length => scalar @{$out},
            recordsTotal => $stats->{total},
            recordsFiltered => $stats->{total},
            results => {
                search_results => $out,
                errors => []
            }
        }
    );

}

sub prep_stats {
    my $response = shift;

    return {
        total => $response->{SearchResult}->{Statistics}->{TotalHits},
    };
}

sub prep_response {
    my $response = shift;

    my $out = [];

    my $records = $response->{SearchResult}->{Data}->{Records};
    foreach my $record(@{$records}) {
        my $url = $record->{PLink};
        my $title = get_title($record);
        my $author = get_author($record);
        my $isbn = get_identifier($record, 'isbn');
        my $issn = get_identifier($record, 'issn');
        my $source = get_source($record);
        my $date = get_date($record);
        push @{$out}, {
            title  => $title,
            author => $author,
            isbn   => $isbn,
            issn   => $issn,
            url    => $url,
            source => $source,
            date   => $date
        };
    }
    return $out;
}

sub get_identifier {
    my ($record, $type) = @_;
    my @i_a = ();
    my $related = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel(@{$related}) {
            my $identifiers = $rel->{BibEntity}->{Identifiers};
            if ($identifiers && scalar @{$identifiers} > 0) {
                @i_a = map {
                    $_->{Type} =~ /^$type/ ? $_->{Value} : ()
                } @{$identifiers};
            }
        }
    }
    return join(', ', @i_a);
}

sub get_date {
    my $record = shift;
    my @date_a = ();
    my $related = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel(@{$related}) {
            my $dates = $rel->{BibEntity}->{Dates};
            if ($dates) {
                @date_a = map { $_->{Text} } @{$dates};
            }
        }
    }
    return join('; ', @date_a);
}

sub get_source {
    my $record = shift;
    my @source_a = ();
    my $related = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel(@{$related}) {
            my $titles = $rel->{BibEntity}->{Titles};
            if ($titles) {
                @source_a = map { $_->{TitleFull} } @{$titles};
            }
        }
    }
    return join('; ', @source_a);
}

sub get_author {
    my $record = shift;
    my @authors_a = ();
    my $authors = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{HasContributorRelationships};
    if ($authors) {
        @authors_a = map { $_->{PersonEntity}->{Name}->{NameFull} } @{$authors};
    }
    return join(', ', @authors_a);
}

sub get_title {
    my $record = shift;
    my @titles_a = ();
    my $titles = $record->{RecordInfo}->{BibRecord}->{BibEntity}->{Titles};
    if ($titles) {
        @titles_a = map { $_->{TitleFull} } @{$titles};
    }
    return join('; ', @titles_a);
}

sub parse_response {
    my ($response, $config) = @_;
    if ( !$response->is_success ) {
        return_error(
            $config->c,
            $config->{err_code},
            "$config->{error}: $response->status_line"
        );
    }

    return decode_json($response->decoded_content);
}

sub prep_param {
    my ($key, $value) = @_;
    return "{AND},{$key}:{$value}";
}

sub return_error {
    my ($c, $code, $error) = @_;
    return $c->render(
        status => $code,
        openapi => {
            results => {
                search_results => [],
                errors => [ { message => $error }]
            }
        }
    );
}

1;
