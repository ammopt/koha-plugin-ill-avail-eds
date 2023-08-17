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

use JSON         qw( decode_json );
use MIME::Base64 qw( decode_base64 );
use URI::Escape  qw ( uri_unescape uri_escape_utf8 );
use POSIX        qw ( floor );
use LWP::UserAgent;
use HTTP::Request::Common;

use Mojo::Base 'Mojolicious::Controller';
use Koha::Database;
use Koha::Plugin::Com::PTFSEurope::AvailabilityEds;

my $base_url = "https://eds-api.ebscohost.com/";
my $ua       = LWP::UserAgent->new;

sub search {
    my $c = shift->openapi->valid_input or return;

    my $start      = $c->validation->param('start')    || 0;
    my $metadata   = $c->validation->param('metadata') || '';
    my $pageLength = $c->validation->param('length') == -1 ? 100 : 20;

    # ILL request metadata coming from 'create' form
    $metadata = decode_json( decode_base64( uri_unescape($metadata) ) );

    # EBSCO to Koha ILL fieldmap, ordered by most relevant koha field match
    my %fieldmap = (
        TI => [ 'article_title',  'chapter',        'title' ],
        AU => [ 'article_author', 'chapter_author', 'author' ],
        IB => ['isbn'],
        IS => ['issn'],
        TX => ['doi']
    );

    my %params = ();

    foreach my $ebsco_code ( keys %fieldmap ) {
        foreach my $koha_field ( @{ $fieldmap{$ebsco_code} } ) {

            # Check if this koha field exists in the submitted in metadata
            if ( $metadata->{$koha_field} && length $metadata->{$koha_field} > 0 ) {
                $params{$ebsco_code} = $metadata->{$koha_field};

                # Most relevant koha field for this ebsco code was found. Bail
                last;
            }
        }
    }

    # Bail out if we have nothing to search with
    if ( !keys %params ) {
        return_error( $c, 400, 'No searchable metadata found' );
    }

    # EBSCO search parameters, use only relevant fields where applicable
    my @search_params = ();

    # If a book and we have an ISBN, use only that
    if ( $metadata->{type} eq 'book' && $params{IB} ) {
        push @search_params, prep_param( 'IB', $params{IB} );

    # If a journal and we have an ISSN, use only that
    } elsif ( $metadata->{type} eq 'journal' && $params{IS} ) {
        push @search_params, prep_param( 'IS', $params{IS} );

    # If we have a DOI, use only that
    } elsif ( $params{TX} ) {
        push @search_params, prep_param( 'TX', $params{TX} );

    # None of the above applies; use all submitted fields
    } else {
        foreach my $p ( keys %params ) {
            push @search_params, prep_param( $p, $params{$p} );
        }
    }

    if ( @search_params == 0 ) {
        return_error(
            $c,
            400,
            'Unable to form search query with supplied metadata'
        );
    }

    my $search_string = join( ' AND ', @search_params );

    # Handle EBSCO authentication
    my $auth_token    = get_auth_token($c);
    my $session_token = get_session_token( $c, $auth_token );

    my @search_headers = (
        'Accept'                => 'application/json',
        'x-sessionToken'        => $session_token,
        'x-authenticationToken' => $auth_token
    );

    # Calculate which page of result we're requesting
    my $page            = floor( $start / $pageLength ) + 1;
    my $search_response = $ua->request(
        GET
            "${base_url}edsapi/rest/Search?query=$search_string&resultsperpage=$pageLength&pagenumber=$page&includefacets=n&expander=fulltext",
        @search_headers
    );

    my $search_body = parse_response(
        $search_response,
        { c => $c, err_code => 500, error => 'Unable to get search results' }
    );

    my $out   = prep_response($search_body);
    my $stats = prep_stats($search_body);

    return $c->render(
        status  => 200,
        openapi => {
            start           => $start,
            pageLength      => scalar @{$out},
            recordsTotal    => $stats->{total},
            recordsFiltered => $stats->{total},
            results         => {
                search_results => $out,
                errors         => []
            }
        }
    );
}

sub fulltext {

    # Validate what we've received
    my $c = shift->openapi->valid_input or return;

    my $an   = $c->validation->param('an')   || '';
    my $dbid = $c->validation->param('dbid') || '';

    # Bail out if we do not have what we need
    if ( length $an == 0 ) {
        return_error( $c, 400, 'No accession number found' );
    }
    if ( length $dbid == 0 ) {
        return_error( $c, 400, 'No database ID found' );
    }

    # We should be OK to continue,
    # so let's start the process by authenticating
    my $auth_token    = get_auth_token($c);
    my $session_token = get_session_token( $c, $auth_token );

    my @retrieve_headers = (
        'Accept'                => 'application/json',
        'x-sessionToken'        => $session_token,
        'x-authenticationToken' => $auth_token
    );
    my $retrieve_response = $ua->request(
        GET "${base_url}edsapi/rest/retrieve?dbid=$dbid&an=$an",
        @retrieve_headers
    );

    my $retrieve_body = parse_response(
        $retrieve_response,
        { c => $c, err_code => 500, error => 'Unable to get search results' }
    );

    my $links = $retrieve_body->{Record}->{FullText}->{Links};

    if ( $links && scalar @{$links} > 0 ) {
        my $url = ${$links}[0]->{Url};
        if ($url) {
            return $c->redirect_to($url);
        }
    }
    return $c->render(
        status  => 404,
        openapi => { errors => [ { message => 'Unable to locate fulltext' } ] }
    );
}

sub get_plugin_config {
    my $plugin = Koha::Plugin::Com::PTFSEurope::AvailabilityEds->new();
    return $plugin->{config};
}

sub get_auth_token {

    my ($c) = @_;

    # Check we've got a userid and password specified in the config,
    # if not, we're using IP authentication
    my $plugin_config = get_plugin_config;
    my $userid        = $plugin_config->{ill_avail_eds_userid};
    my $password      = $plugin_config->{ill_avail_eds_password};

    # How we proceed depends on our authentication method, if we have
    # a userid and password specified in the config, we use those
    my $url;
    my $body;
    if ( $userid && length $userid > 0 && $password && length $password > 0 ) {
        $url  = 'authservice/rest/uidauth';
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

    my $auth_response = $ua->request(
        POST "${base_url}${url}",
        @auth_headers,
        Content => $body
    );

    my $auth_body = parse_response(
        $auth_response,
        { c => $c, err_code => 500, error => 'Unable to authenticate to EDS' }
    );

    if ( !exists $auth_body->{AuthToken} ) {
        return_error(
            $c,
            500,
            'Unable to authenticate to EDS: ' . $auth_response->decoded_content
        );
    }

    return $auth_body->{AuthToken};
}

sub get_session_token {
    my ( $c, $auth_token ) = @_;

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
        { c => $c, err_code => 500, error => 'Unable to get session token' }
    );

    if ( !exists $session_body->{SessionToken} ) {
        return_error(
            $c,
            500,
            'Unable to get session token: ' . $session_response->decoded_content
        );
    }

    return $session_body->{SessionToken};
}

sub prep_stats {
    my $response = shift;

    return {
        total => $response->{SearchResult}->{Statistics}->{TotalHits},
    };
}

sub prep_response {
    my $response = shift;

    my $out           = [];
    my $plugin_config = get_plugin_config;

    my $records = $response->{SearchResult}->{Data}->{Records};
    foreach my $record ( @{$records} ) {
        my $url      = $record->{PLink};
        my $title    = get_title($record);
        my $author   = get_author($record);
        my $isbn     = get_identifier( $record, 'isbn' );
        my $issn     = get_identifier( $record, 'issn' );
        my $source   = get_source($record);
        my $date     = get_date($record);
        my $fulltext = get_fulltext($record);

        # If fulltext_only config is true, skip this result if it doesn't have it
        if (   defined $plugin_config->{ill_avail_display_fulltext_only}
            && $plugin_config->{ill_avail_display_fulltext_only} eq "y"
            && !$record->{FullText}->{Text}->{Availability} )
        {
            next;
        }

        push @{$out}, {
            title  => $title,
            author => $author,
            isbn   => $isbn,
            issn   => $issn,
            url    => $url,
            source => $source,
            date   => $date,
            links  => $fulltext
        };
    }
    return $out;
}

sub get_fulltext {
    my ($record) = @_;

    my @return = ();

    # The logic for deriving whether we have full text available
    # has been mostly formed using the sources:
    # https://github.com/ebsco/edsapi-php-sample
    # and
    # https://connect.ebsco.com/s/article/EBSCO-Discovery-Service-API-User-Guide

    my $fulltext = $record->{FullText};

    # PDF full text
    if ( $fulltext->{Links} ) {
        foreach my $link ( @{ $fulltext->{Links} } ) {
            if ( $link->{Type} eq 'pdflink' || $link->{Type} eq 'other' ) {
                my $an   = get_an($record);
                my $dbid = get_dbid($record);
                push @return, {
                    text => 'Download fulltext',
                    url  => "/api/v1/contrib/ill_availability_eds/ill_availability_eds_fulltext?an=$an&dbid=$dbid"
                };
            }
        }

    }
    if ( $fulltext->{CustomLinks} ) {
        foreach my $custom_link ( @{ $fulltext->{CustomLinks} } ) {
            push @return, {
                text => $custom_link->{Text},
                url  => $custom_link->{Url}
            };
        }
    }
    return \@return;
}

sub get_an {
    my ($record) = @_;

    return $record->{Header}->{An};
}

sub get_dbid {
    my ($record) = @_;

    return $record->{Header}->{DbId};
}

sub get_identifier {
    my ( $record, $type ) = @_;
    my @i_a     = ();
    my $related = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel ( @{$related} ) {
            my $identifiers = $rel->{BibEntity}->{Identifiers};
            if ( $identifiers && scalar @{$identifiers} > 0 ) {
                @i_a = map { $_->{Type} =~ /^$type/ ? $_->{Value} : () } @{$identifiers};
            }
        }
    }
    return join( ', ', @i_a );
}

sub get_date {
    my $record  = shift;
    my @date_a  = ();
    my $related = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel ( @{$related} ) {
            my $dates = $rel->{BibEntity}->{Dates};
            if ($dates) {
                @date_a = map { $_->{Text} } @{$dates};
            }
        }
    }
    return join( '; ', @date_a );
}

sub get_source {
    my $record   = shift;
    my @source_a = ();
    my $related  = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{IsPartOfRelationships};
    if ($related) {
        foreach my $rel ( @{$related} ) {
            my $titles = $rel->{BibEntity}->{Titles};
            if ($titles) {
                @source_a = map { $_->{TitleFull} } @{$titles};
            }
        }
    }
    return join( '; ', @source_a );
}

sub get_author {
    my $record    = shift;
    my @authors_a = ();
    my $authors   = $record->{RecordInfo}->{BibRecord}->{BibRelationships}->{HasContributorRelationships};
    if ($authors) {
        @authors_a = map { $_->{PersonEntity}->{Name}->{NameFull} } @{$authors};
    }
    return join( ', ', @authors_a );
}

sub get_title {
    my $record   = shift;
    my @titles_a = ();
    my $titles   = $record->{RecordInfo}->{BibRecord}->{BibEntity}->{Titles};
    if ($titles) {
        @titles_a = map { $_->{TitleFull} } @{$titles};
    }
    return join( '; ', @titles_a );
}

sub parse_response {
    my ( $response, $config ) = @_;
    if ( !$response->is_success ) {
        return_error(
            $config->{c},
            $config->{err_code},
            "$config->{error}: $response->status_line"
        );
    }
    return decode_json( $response->decoded_content );
}

sub prep_param {
    my ( $key, $value ) = @_;

    # If we're prepping author, we need to remove commas and fullstops
    # and replace with a space. As per EBSCO advice.
    if ( $key eq 'AU' ) {
        $value =~ s/(\.|,|)/ /g;

        # We also need to try and truncate author to a single name, the
        # following makes the assumption that authors are separated by ;
        # If it's not, $value remains unchanged
        my @author_arr = split( /;/, $value );
        $value = $author_arr[0];
    }

    # Escape and remove characters as necessary
    $value =~ s/(,)/\\$1/g;
    $value =~ s/(&|'|’|:)//g;
    $value = uri_escape_utf8($value);
    return "$key $value";
}

sub return_error {
    my ( $c, $code, $error ) = @_;
    return $c->render(
        status  => $code,
        openapi => {
            results => {
                search_results => [],
                errors         => [ { message => $error } ]
            }
        }
    );
}

1;
