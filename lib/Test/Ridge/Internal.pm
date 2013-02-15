package Test::Ridge::Internal;
use strict;
use warnings;
require utf8;
use HTTP::Request::Common;
use UNIVERSAL::require;
use URI::Escape qw(uri_escape_utf8);
use URI::QueryParam;
use Encode;

require Ridge::Test::Internal;
@Ridge::Test::Internal::EXPORT = ();

our @EXPORT = qw(
    GET PUT POST DELETE HEAD
    with_client_ipaddr
    with_docomo_browser
    with_docomo_20_browser
    with_ezweb_browser
    with_softbank_browser
    with_dsi_browser
    with_3ds_browser
    with_wii_browser
    with_basic_auth
    with_wsse_auth
);

our $DEBUG ||= $ENV{INTERNAL_DEBUG} || 0;

our $UserAgent;
our $ClientIPAddr;
our $DocomoID;
our $EzNumber;
our $SBSerialNumber;
our $OAuthParams;
our $BasicAuth;
our $WSSEAuth;

our $HTTPS_BACKEND_TYPE ||= 'x-forwarded';

sub import {
    my ($class, $ridge_module, $ridge_config_class) = @_;
    die unless $ridge_module;

    Ridge::Test::Internal->import($ridge_module);

    no warnings 'prototype';
    no warnings 'redefine';
    foreach my $method (qw(GET PUT POST DELETE HEAD)) {
        no strict 'refs';
        *{__PACKAGE__ . "::$method"} = sub (&$;$) {
            my ($code, $path, $args) = @_;
            $args ||= [];

            my $uri = URI->new_abs($path, 'http://test.example.com/');

            # cookie
            my $cookie;
            for (my $i=0; $i<=@$args; $i+=2) {
                if (lc($args->[$i]) eq 'cookie') {
                    my ($k, $v) = splice(@$args, $i, 2);
                    $cookie = $v;
                }
            }
            if (ref $cookie eq 'ARRAY') {
                my $cookie_str;
                while (my ($k, $v) = splice(@$cookie, 0, 2)) {
                    $cookie_str .= sprintf("%s=%s;", $k, $v);
                }
                $cookie = $cookie_str;
            }
            elsif (ref $cookie eq 'HASH') {
                my $cookie_str;
                while (my ($k, $v) = each(%$cookie)) {
                    $cookie_str .= sprintf("%s=%s;", $k, $v);
                }
                $cookie = $cookie_str;
            }
            push @$args, 'Cookie' => $cookie if $cookie;

            if (defined $UserAgent) {
                local $UserAgent = $UserAgent;
                if (defined $SBSerialNumber) {
                    $UserAgent =~ s/%%SBSerialNumber%%/\/SN$SBSerialNumber/g;
                } else {
                    $UserAgent =~ s/%%SBSerialNumber%%//g;
                }
                push @$args, 'User-Agent' => $UserAgent;
            }

            if (defined $DocomoID and $path =~ /\?.*?\bguid=on\b/) {
                push @$args, 'X-DCMGUID' => $DocomoID;
            }

            if (defined $SBSerialNumber) {
            }

            if (defined $EzNumber) {
                push @$args, 'X-Up-Subno' => $EzNumber;
            }

            if ($ClientIPAddr) {
                push @$args, 'X-Forwarded-For' => $ClientIPAddr;
            }

            if ($BasicAuth) {
                push @$args, 'Authorization' => $BasicAuth;
            }

            if ($WSSEAuth) {
                push @$args, 'X-WSSE' => $WSSEAuth;
            }

            if ($OAuthParams) {
                require OAuth::Lite::Consumer;
                require OAuth::Lite::Token;
                my $consumer = OAuth::Lite::Consumer->new(
                    consumer_key    => $OAuthParams->{oauth_consumer_key},
                    consumer_secret => $OAuthParams->{oauth_consumer_secret},
                    ($OAuthParams->{oauth_auth_method}
                    ? (auth_method     => $OAuthParams->{oauth_auth_method})
                    : ())
                );
                my $access_token = OAuth::Lite::Token->new(
                    token  => $OAuthParams->{oauth_token},
                    secret => $OAuthParams->{oauth_token_secret},
                );
                $OAuthParams->{params} ||= {};
                %{$OAuthParams->{params} or {}} = map {
                    ref $_ eq 'ARRAY' ? [map { encode 'utf-8', $_ } @$_] : encode 'utf-8', $_;
                } %{$OAuthParams->{params} or {}};
                my $req = $consumer->gen_oauth_request(
                    method => $method,
                    url    => $uri,
                    token  => $access_token,
                    params => $OAuthParams->{params},
                    content => $OAuthParams->{content},
                    headers => $OAuthParams->{headers},
                );
                if(my $auth_header = $req->header('Authorization')) {
                    push @$args, 'Authorization' => $auth_header;
                }
                $uri = $req->uri;
                if (length $req->content) {
                    push @$args, content      => $req->content;
                    push @$args, content_type => $req->content_type;
                }
            }

            my $req = HTTP::Request::Common->can($method)->(
                $uri,
                @$args
            );
            if ($DEBUG >= 1) {
                print STDERR "========== REQUEST ==========\n";
                print STDERR $req->method, ' ', $req->uri, "\n";
                print STDERR $req->headers->as_string;
                print STDERR "\n";
                print STDERR $req->content, "\n" if $DEBUG >= 2;
                print STDERR "======== INTERNAL TEST ======\n";
            }
            my $host = $req->uri->authority;
            $host = '' unless defined $host;
            $host =~ s/^[^\@]*\@//;
            # XXX $host の percent_decode もしたほうがいいのかなあ。

            local %ENV = %ENV;
            if ($uri->scheme eq 'https' and $HTTPS_BACKEND_TYPE eq 'x-forwarded') {
                $ENV{HTTP_X_FORWARDED_SCHEME} = 'HTTPS';
                $ENV{HTTPS} = 'on';
            }
            my $c;
            my @test_process_arg;
            if ($XXX::PlackedRidge) {
                my $env = $req->to_psgi;
                $env->{REMOTE_ADDR} = '123.45.78.9'; # for compat with tests
                $env->{HTTPS} = 1
                    if $HTTPS_BACKEND_TYPE eq 'env' and
                       $uri->scheme eq 'https'; # for compat
                $env->{HTTP_HOST} ||= $host;
                @test_process_arg = ($env);
                for (grep { /^[A-Z0-9_]+$/ } keys %$env) {
                    $ENV{$_} = $env->{$_};
                }
                $ENV{RIDGE_ENV} = 'test';
            } else {
                HTTP::Request::AsCGI->require;
                $c = HTTP::Request::AsCGI->new(
                    $req,
                    RIDGE_ENV   => 'test',
                    RIDGE_DEBUG => $ENV{RIDGE_DEBUG} || '',
                    REMOTE_ADDR => '123.45.78.9',
                    ($HTTPS_BACKEND_TYPE eq 'env' ?
                        (HTTPS       => ($uri->scheme eq 'https' ? 1 : undef)) :
                        ()
                    ),
                )->setup;
                $ENV{HTTP_HOST} = $host;
            }

            $ridge_module->require or die $@;

            $ridge_config_class ||= "${ridge_module}::Config";
            $ridge_config_class->require or die $@;

            my $root = $ridge_config_class->load->param('root');
            local $_ = $ridge_module->test_process(@test_process_arg, { root => $root });
            local $Test::Builder::Level = $Test::Builder::Level + 2;
            $code->();
        };
    }

    my ($copy) = caller;
    no strict 'refs';
    for my $method (@{$class . '::EXPORT'}) {
        *{$copy . '::' . $method} = $class->can($method);
    }
}

sub with_client_ipaddr (&$) {
    my ($code, $ipaddr) = @_;

    local $ClientIPAddr = $ipaddr;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $code->();
}

sub with_docomo_browser (&;$) {
    my ($code, $docomo_id) = @_;
    $docomo_id =~ s/I$// if $docomo_id;

    local $UserAgent = 'DoCoMo/1.0/N506iS/c20/TB/W20H11';
    #local $ClientIPAddr = XXX;
    local $DocomoID = $docomo_id;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $code->();
}

sub with_docomo_20_browser (&;$) {
    my ($code, $docomo_id) = @_;
    $docomo_id =~ s/I$// if $docomo_id;

    local $UserAgent = 'DoCoMo/2.0 P07A(c500;TB;W24H15)';
    #local $ClientIPAddr = XXX;
    local $DocomoID = $docomo_id;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $code->();
}

sub with_ezweb_browser (&;$) {
    my ($code, $ez_number) = @_;
    $ez_number =~ s/E$// if $ez_number;

    local $UserAgent = 'KDDI-SA31 UP.Browser/6.2.0.7.3.129 (GUI) MMP/2.0';
    #local $ClientIPAddr = XXX;
    local $EzNumber = $ez_number;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $code->();
}

sub with_softbank_browser (&;$) {
    my ($code, $sn) = @_;
    $sn =~ s/V$// if $sn;

    local $UserAgent = 'SoftBank/1.0/910T/TJ001%%SBSerialNumber%% Browser/NetFront/3.3 Profile/MIDP-2.0 Configuration/CLDC-1.1';
    #local $ClientIPAddr = XXX;
    local $SBSerialNumber = $sn;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $code->();
}

sub with_basic_auth (&$) {
    my ($code, $args) = @_;

    my $id = $args->{userid};
    $id = '' unless defined $id;
    my $pass = $args->{password};
    $pass = '' unless defined $pass;

    require MIME::Base64;
    my $field_body = 'Basic ' . MIME::Base64::encode_base64($id . ':' . $pass);

    local $BasicAuth = $field_body;
    $code->();
}

sub with_wsse_auth (&$) {
    my ($code, $args) = @_;

    my $username = $args->{userid};
    my $password = $args->{password};
    $username = '' unless defined $username;
    $password = '' unless defined $password;

    require Digest::SHA1;
    require MIME::Base64;
    my $nonce = Digest::SHA1::sha1(Digest::SHA1::sha1(time() . {} . rand() . $$));
    my $now = DateTime->now->iso8601 . 'Z';
    my $digest = MIME::Base64::encode_base64(Digest::SHA1::sha1($nonce . $now . $password), '');
    my $credentials = sprintf(qq(UsernameToken Username="%s", PasswordDigest="%s", Nonce="%s", Created="%s"),
        $username, $digest, MIME::Base64::encode_base64($nonce, ''), $now);

    local $WSSEAuth = $credentials;
    $code->();
}

for my $b (
    [
        iphone =>
        'Mozilla/5.0 (iPhone; U; CPU iPhone OS 3_1_3 like Mac OS X; ja-jp) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16',
    ],
    [
        ipod =>
        'Mozilla/5.0 (iPod; U; CPU iPhone OS 3_1_3 like Mac OS X; ja-jp) AppleWebKit/528.18 (KHTML, like Gecko) Version/4.0 Mobile/7E18 Safari/528.16',
    ],
    [
        ipad =>
        'Mozilla/5.0 (iPad; U; CPU OS 3_2 like Mac OS X; ja-jp) AppleWebKit/531.21.10 (KHTML, like Gecko) Version/4.0.4 Mobile/7B367 Safari/531.21.10',
    ],
    [
        android =>
        'Mozilla/5.0 (Linux; U; Android 1.6; ja-jp; SonyEricssonSO-01B Build/R1EA018) AppleWebKit/528.5+ (KHTML, like Gecko) Version/3.1.2 Mobile Safari/525.20.1',
    ],
    [
        dsi =>
        'Opera/9.50 (Nintendo DSi; Opera/507; U; ja)',
    ],
    [
        '3ds' =>
        'Mozilla/5.0 (Nintendo 3DS; U; ; ja) Version/1.7412.JP'
    ],
    [
        wii =>
        'Opera/9.30 (Nintendo Wii; U; ; 3642; ja)',
    ],
    [
        firefox =>
        'Mozilla/5.0 (Windows; U; Windows NT 5.1; ja; rv:1.9.1.9) Gecko/20100315 Firefox/3.5.9',
    ],
    [
        safari =>
        'Mozilla/5.0 (Windows; U; Windows NT 5.1; ja-JP) AppleWebKit/531.21.8 (KHTML, like Gecko) Version/4.0.4 Safari/531.21.10',
    ],
    [
        chrome =>
        'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US) AppleWebKit/533.4 (KHTML, like Gecko) Chrome/5.0.375.29 Safari/533.4',
    ],
    [
        opera =>
        'Opera/9.80 (Windows NT 6.0; U; ja) Presto/2.5.22 Version/10.51',
    ],
    [
        ie =>
        'Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 5.1; .NET CLR 1.1.4322; IEMB3; IEMB3)',
    ],
    [
        googlebot =>
        'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
    ],
    [
        googlebot_mobile =>
        'DoCoMo/2.0 N905i(c100;TB;W24H16) (compatible; Googlebot-Mobile/2.1; +http://www.google.com/bot.html)',
    ],
) {
    eval sprintf q{
        sub with_%s_browser (&) {
            my ($code) = @_;

            local $UserAgent = q[%s];

            local $Test::Builder::Level = $Test::Builder::Level + 1;
            $code->();
        }
        1;
    }, $b->[0], $b->[1] or die $@;
    push @EXPORT, sprintf 'with_%s_browser', $b->[0];
}

1;
