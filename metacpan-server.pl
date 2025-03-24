#!/usr/bin/env perl
use 5.38.0;
use experimental qw(class try builtin);
use lib::xi;

use FindBin;
use local::lib "$FindBin::Bin/../local";
use HTTP::Tiny;
use IO::Handle;

# Set stdout and stderr to be unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Protocol constants
my $PROTOCOL_VERSION = "2024-11-05";
my $SERVER_NAME      = "metacpan";
my $SERVER_VERSION   = "1.0.0";

# Logger class
class Logger {
    field $file :param;

    ADJUST {
        if ($file) {
            open STDERR, ">>", $file or die "Failed to open log file: $!";
        }
    }

    method log ( $message, @ ) {
        say STDERR "[MCP Server] $message";
    }
}

# Configuration class
class Config {
    field $metacpan_api_url :param :reader = $ENV{METACPAN_API_URL}
      // 'https://fastapi.metacpan.org/v1';
    field $debug :param :reader       = $ENV{DEBUG}       // 0;
    field $log_file :param :reader    = $ENV{LOG_FILE}    // '';
    field $cache_ttl :param :reader   = $ENV{CACHE_TTL}   // 3600;
    field $max_results :param :reader = $ENV{MAX_RESULTS} // 10;
    field $timeout :param :reader     = $ENV{TIMEOUT}     // 10;
}

# Cache Manager class
class CacheManager {
    field $config :param;
    field $logger :param;
    field %cache;
    field %timestamps;

    method get ($key) {
        my $now = time();
        if ( exists $cache{$key} ) {
            my $ttl = $timestamps{$key} + $config->cache_ttl;
            if ( $ttl > $now ) {
                $logger->log( "Cache hit for key: $key", 'debug' );
                return $cache{$key};
            }
            $logger->log( "Cache expired for key: $key", 'debug' );
            delete $cache{$key};
            delete $timestamps{$key};
        }
        return undef;
    }

    method set ( $key, $value, $ttl = undef ) {
        $cache{$key}      = $value;
        $timestamps{$key} = time();
        $logger->log( "Set cache for key: $key", 'debug' );
        return $value;
    }

    method has ($key) {
        my $now = time();
        if ( exists $cache{$key} ) {
            my $ttl = $timestamps{$key} + $config->cache_ttl;
            return $ttl > $now;
        }
        return 0;
    }

    method invalidate ($key) {
        delete $cache{$key};
        delete $timestamps{$key};
        $logger->log( "Invalidated cache for key: $key", 'debug' );
    }

    method clear {
        %cache      = ();
        %timestamps = ();
        $logger->log( "Cleared entire cache", 'debug' );
    }
}

# MetaCPAN API Client
class MetaCPANClient {
    use JSON::PP    qw(decode_json);
    use URI::Escape qw(uri_escape_utf8);

    field $config :param;
    field $logger :param;
    field $ua = HTTP::Tiny->new(
        timeout => $config->timeout,
        agent   => "perigrin-MetaCPAN-MCP-Server/$SERVER_VERSION",
    );

    method search_modules ( $query, $size = 10 ) {
        $logger->log( "Searching for modules: $query (size: $size)", 'debug' );

        # Change to release endpoint which is better for author queries
        my $url = $config->metacpan_api_url . "/release/_search";

        # Format the fields as comma-separated string
        my $params = {
            q      => $query,
            size   => $size,
            fields => "name,abstract,author,version,date,status,distribution"
        };

        my $result = $self->_make_request( $url, $params );
        return $result;
    }

    method get_module ($module_name) {
        $logger->log( "Getting module info: $module_name", 'debug' );

        my $escaped_name = uri_escape_utf8($module_name);
        my $url          = $config->metacpan_api_url . "/module/$escaped_name";

        my $result = $self->_make_request($url);
        return $result;
    }

    method get_documentation ( $module_name, $section = 'all' ) {
        $logger->log(
"Getting documentation for module: $module_name (section: $section)",
            'debug'
        );

        my $escaped_name = uri_escape_utf8($module_name);
        my $url          = $config->metacpan_api_url . "/pod/$escaped_name";

        if ( $section ne 'all' ) {
            $url .= "/$section";
        }

        my $result = $self->_make_request($url);
        return $result;
    }

    method get_dependencies ($module_name) {
        $logger->log( "Getting dependencies for module: $module_name",
            'debug' );

        # First get the distribution name from the module
        my $module_info = $self->get_module($module_name);
        if ( !$module_info || !$module_info->{distribution} ) {
            return { error => "Module not found or has no distribution" };
        }

        my $dist_name = $module_info->{distribution};
        my $url       = $config->metacpan_api_url . "/release/$dist_name";

        my $result = $self->_make_request($url);
        return $result;
    }

    method get_author ($author_id) {
        $logger->log( "Getting author info: $author_id", 'debug' );

        my $url = $config->metacpan_api_url . "/author/$author_id";

        my $result = $self->_make_request($url);
        return $result;
    }

    method _make_request ( $url, $params = {} ) {
        my $query_string = '';

        if (%$params) {
            $query_string = '?' . join(
                '&',
                map {
                    my $key   = $_;
                    my $value = $params->{$key};
                    "$key=" . uri_escape_utf8($value);
                } keys %$params
            );
        }

        my $full_url = $url . $query_string;
        $logger->log( "Making request to: $full_url", 'debug' );

        my $headers = {
            'Accept'       => 'application/json',
            'Content-Type' => 'application/json',
        };

        my $response = $ua->get( $full_url, { headers => $headers } );

        if ( $response->{success} ) {
            try {
                return decode_json( $response->{content} );
            }
            catch ($e) {
                $logger->log( "Failed to decode JSON: $e", 'error' );
                return { error => "Failed to decode response: $e" };
            }
        }
        else {
            $logger->log(
                "Request failed: $response->{status} $response->{reason}",
                'error' );
            return {
                error =>
                  "Request failed: $response->{status} $response->{reason}",
                status  => $response->{status},
                content => $response->{content}
            };
        }
    }
}

# Tool implementations
class ModuleSearchTool {
    field $api_client :param;
    field $cache :param;
    field $logger :param;
    field $config :param;

    method execute ($params) {
        my $query = $params->{query} // '';
        my $size  = $params->{size}  // $config->max_results;

        if ( !$query ) {
            return {
                is_error => JSON::PP::true,
                content  => "Query parameter is required"
            };
        }

        # Try cache first
        my $cache_key = "module_search:$query:$size";
        if ( $cache->has($cache_key) ) {
            return $cache->get($cache_key);
        }

        # Call API
        my $results = $api_client->search_modules( $query, $size );

        # Check for errors
        if ( $results->{error} ) {
            return {
                is_error => JSON::PP::true,
                content  => "Error searching modules: " . $results->{error}
            };
        }

        # Format results
        my $formatted = $self->format_results( $results, $query );

        # Cache results
        $cache->set( $cache_key, $formatted );

        return $formatted;
    }

    method format_results ( $results, $query ) {
        my $output = "# Search Results for \"$query\"\n\n";

        if (   !$results->{hits}
            || !$results->{hits}{total}
            || $results->{hits}{total} == 0 )
        {
            return { content =>
                  [ $output . "No modules found matching your query." ] };
        }

        $output .=
            "Found "
          . $results->{hits}{total}
          . " modules. Showing top matches:\n\n";

        foreach my $hit ( @{ $results->{hits}{hits} } ) {
            my $module = $hit->{fields};
            $output .= "## " . ( $module->{module} // 'Unknown' ) . "\n";
            $output .=
              "**Version**: " . ( $module->{version} // 'Unknown' ) . "\n";
            $output .=
              "**Author**: " . ( $module->{author} // 'Unknown' ) . "\n";
            $output .= "**Distribution**: "
              . ( $module->{distribution} // 'Unknown' ) . "\n";
            $output .=
              "**Released**: " . ( $module->{date} // 'Unknown' ) . "\n";
            $output .=
              "**Status**: " . ( $module->{status} // 'Unknown' ) . "\n";
            $output .= "**Abstract**: "
              . ( $module->{abstract} // 'No description available' ) . "\n\n";
            $output .= "---\n\n";
        }

        return { content => [ { type => "text", text => $output } ] };
    }
}

class ModuleInfoTool {
    field $api_client :param;
    field $cache :param;
    field $logger :param;
    field $config :param;

    method execute ($params) {
        my $module_name = $params->{module} // '';

        if ( !$module_name ) {
            return {
                is_error => JSON::PP::true,
                content  => "Module parameter is required"
            };
        }

        # Try cache first
        my $cache_key = "module_info:$module_name";
        if ( $cache->has($cache_key) ) {
            return $cache->get($cache_key);
        }

        # Call API
        my $module_data = $api_client->get_module($module_name);

        # Check for errors
        if ( $module_data->{error} ) {
            return {
                is_error => JSON::PP::true,
                content => "Error getting module info: " . $module_data->{error}
            };
        }

        # Format results
        my $formatted = $self->format_module_info( $module_data, $module_name );

        # Cache results
        $cache->set( $cache_key, $formatted );

        return $formatted;
    }

    method format_module_info ( $module_data, $module_name ) {
        if ( !$module_data || ref($module_data) ne 'HASH' ) {
            return {
                content => [
                    {
                        type => "text",
                        text => "No information found for module $module_name"
                    }
                ]
            };
        }

        my $output = "# Module: $module_name\n\n";

        $output .=
          "**Version**: " . ( $module_data->{version} // 'Unknown' ) . "\n";
        $output .= "**Abstract**: "
          . ( $module_data->{abstract} // 'No description available' ) . "\n";
        $output .= "**Distribution**: "
          . ( $module_data->{distribution} // 'Unknown' ) . "\n";
        $output .=
          "**Author**: " . ( $module_data->{author} // 'Unknown' ) . "\n";
        $output .=
          "**Release Date**: " . ( $module_data->{date} // 'Unknown' ) . "\n";
        $output .=
          "**License**: " . ( $module_data->{license} // 'Unknown' ) . "\n";

        if ( $module_data->{metadata} && $module_data->{metadata}{prereqs} ) {
            $output .= "\n## Dependencies\n\n";

            foreach
              my $phase ( sort keys %{ $module_data->{metadata}{prereqs} } )
            {
                $output .= "### $phase\n\n";

                foreach my $type (
                    sort keys %{ $module_data->{metadata}{prereqs}{$phase} } )
                {
                    $output .= "#### $type\n\n";

                    my $deps = $module_data->{metadata}{prereqs}{$phase}{$type};
                    foreach my $dep ( sort keys %$deps ) {
                        $output .= "* **$dep**: " . $deps->{$dep} . "\n";
                    }

                    $output .= "\n";
                }
            }
        }

        return { content => [ { type => "text", text => $output } ] };
    }
}

class DocumentationTool {
    field $api_client :param;
    field $cache :param;
    field $logger :param;
    field $config :param;

    method execute ($params) {
        my $module_name = $params->{module}  // '';
        my $section     = $params->{section} // 'all';

        if ( !$module_name ) {
            return {
                is_error => JSON::PP::true,
                content  => "Module parameter is required"
            };
        }

        # Try cache first
        my $cache_key = "documentation:$module_name:$section";
        if ( $cache->has($cache_key) ) {
            return $cache->get($cache_key);
        }

        # Call API
        my $documentation =
          $api_client->get_documentation( $module_name, $section );

        # Check for errors
        if ( $documentation->{error} ) {
            return {
                is_error => JSON::PP::true,
                content  => "Error getting documentation: "
                  . $documentation->{error}
            };
        }

        # Format results
        my $formatted =
          $self->format_documentation( $documentation, $module_name, $section );

        # Cache results
        $cache->set( $cache_key, $formatted );

        return $formatted;
    }

    method format_documentation ( $documentation, $module_name, $section ) {
        if ( !$documentation ) {
            return {
                content => [
                    {
                        type => "text",
                        text => "No documentation found for $module_name"
                    }
                ]
            };
        }

        my $title =
          $section eq 'all' ? $module_name : "$module_name - $section";
        my $output = "# Documentation: $title\n\n";

        if ( $documentation->{pod} ) {
            $output .= $documentation->{pod} . "\n";
        }
        elsif ( $section ne 'all' && $documentation->{pod_section} ) {
            $output .= "## $section\n\n";
            $output .= $documentation->{pod_section} . "\n";
        }
        else {
            $output .= "No documentation content found.\n";
        }

        return { content => [ { type => "text", text => $output } ] };
    }
}

class DependencyTool {
    field $api_client :param;
    field $cache :param;
    field $logger :param;
    field $config :param;

    method execute ($params) {
        my $module_name = $params->{module} // '';

        if ( !$module_name ) {
            return {
                is_error => JSON::PP::true,
                content  => "Module parameter is required"
            };
        }

        # Try cache first
        my $cache_key = "dependencies:$module_name";
        if ( $cache->has($cache_key) ) {
            return $cache->get($cache_key);
        }

        # Call API
        my $dependencies = $api_client->get_dependencies($module_name);

        # Check for errors
        if ( $dependencies->{error} ) {
            return {
                is_error => JSON::PP::true,
                content  => "Error getting dependencies: "
                  . $dependencies->{error}
            };
        }

        # Format results
        my $formatted =
          $self->format_dependencies( $dependencies, $module_name );

        # Cache results
        $cache->set( $cache_key, $formatted );

        return $formatted;
    }

    method format_dependencies ( $dependencies, $module_name ) {
        if ( !$dependencies || ref($dependencies) ne 'HASH' ) {
            return {
                content => [
                    {
                        type => "text",
                        text =>
                          "No dependency information found for $module_name"
                    }
                ]
            };
        }

        my $output = "# Dependencies for $module_name\n\n";

        $output .=
          "**Distribution**: " . ( $dependencies->{name} // 'Unknown' ) . "\n";
        $output .=
          "**Version**: " . ( $dependencies->{version} // 'Unknown' ) . "\n";
        $output .=
          "**Author**: " . ( $dependencies->{author} // 'Unknown' ) . "\n\n";

        if ( $dependencies->{metadata} && $dependencies->{metadata}{prereqs} ) {
            foreach my $phase (qw(runtime build test configure develop)) {
                next unless $dependencies->{metadata}{prereqs}{$phase};

                $output .= "## $phase Dependencies\n\n";

                foreach my $type (qw(requires recommends suggests)) {
                    next
                      unless $dependencies->{metadata}{prereqs}{$phase}{$type};

                    $output .= "### $type\n\n";

                    my $deps =
                      $dependencies->{metadata}{prereqs}{$phase}{$type};
                    foreach my $dep ( sort keys %$deps ) {
                        $output .= "* **$dep**: " . $deps->{$dep} . "\n";
                    }

                    $output .= "\n";
                }
            }
        }
        else {
            $output .= "No dependency information available in the metadata.\n";
        }

        return { content => [ { type => "text", text => $output } ] };
    }
}

class AuthorInfoTool {
    field $api_client :param;
    field $cache :param;
    field $logger :param;
    field $config :param;

    method execute ($params) {
        my $author_id = $params->{author} // '';

        if ( !$author_id ) {
            return {
                is_error => JSON::PP::true,
                content  => "Author parameter is required"
            };
        }

        # Try cache first
        my $cache_key = "author_info:$author_id";
        if ( $cache->has($cache_key) ) {
            return $cache->get($cache_key);
        }

        # Call API
        my $author_data = $api_client->get_author($author_id);

        # Check for errors
        if ( $author_data->{error} ) {
            return {
                is_error => JSON::PP::true,
                content => "Error getting author info: " . $author_data->{error}
            };
        }

        # Format results
        my $formatted = $self->format_author_info( $author_data, $author_id );

        # Cache results
        $cache->set( $cache_key, $formatted );

        return $formatted;
    }

    method format_author_info ( $author_data, $author_id ) {
        if ( !$author_data || ref($author_data) ne 'HASH' ) {
            return {
                content => [
                    {
                        type => "text",
                        text => "No information found for author $author_id"
                    }
                ]
            };
        }

        my $output =
          "# Author: " . ( $author_data->{name} // $author_id ) . "\n\n";

        $output .=
          "**PAUSE ID**: " . ( $author_data->{pauseid} // $author_id ) . "\n";
        $output .=
          "**Email**: " . ( $author_data->{email} // 'Not provided' ) . "\n";

        if ( $author_data->{website} ) {
            $output .= "**Website**: "
              . join( ', ', @{ $author_data->{website} } ) . "\n";
        }

        if (   $author_data->{city}
            || $author_data->{region}
            || $author_data->{country} )
        {
            $output .= "**Location**: "
              . join(
                ', ',
                grep { $_ } (
                    $author_data->{city}, $author_data->{region},
                    $author_data->{country}
                )
              ) . "\n";
        }

        if ( $author_data->{profile} ) {
            $output .= "\n## Profiles\n\n";
            foreach my $profile ( @{ $author_data->{profile} } ) {
                $output .=
                  "* **" . $profile->{name} . "**: " . $profile->{id} . "\n";
            }
        }

        return { content => [ { type => "text", text => $output } ] };
    }
}

# MCP Server Core
class MCPServer {
    use JSON::PP qw(encode_json decode_json);
    use builtin  qw(true false);

    field $config :param;
    field $logger     = Logger->new( file => $config->log_file, );
    field $api_client = MetaCPANClient->new(
        config => $config,
        logger => $logger
    );
    field $cache = CacheManager->new(
        config => $config,
        logger => $logger
    );

    # Tool instances
    field $module_search_tool = undef;
    field $module_info_tool   = undef;
    field $documentation_tool = undef;
    field $dependency_tool    = undef;
    field $author_info_tool   = undef;

    field $buffer = '';

    ADJUST {
        # Initialize tool instances
        $module_search_tool = ModuleSearchTool->new(
            api_client => $api_client,
            cache      => $cache,
            logger     => $logger,
            config     => $config
        );

        $module_info_tool = ModuleInfoTool->new(
            api_client => $api_client,
            cache      => $cache,
            logger     => $logger,
            config     => $config
        );

        $documentation_tool = DocumentationTool->new(
            api_client => $api_client,
            cache      => $cache,
            logger     => $logger,
            config     => $config
        );

        $dependency_tool = DependencyTool->new(
            api_client => $api_client,
            cache      => $cache,
            logger     => $logger,
            config     => $config
        );

        $author_info_tool = AuthorInfoTool->new(
            api_client => $api_client,
            cache      => $cache,
            logger     => $logger,
            config     => $config
        );
    }

    method run {
        $logger->log(
            "Starting MetaCPAN MCP server (version $SERVER_VERSION)...");
        $logger->log( "Using MetaCPAN API at: " . $config->metacpan_api_url );
        $logger->log("Server ready. Waiting for input...");

        # Simple line-by-line processing loop
        while ( my $line = <STDIN> ) {
            $buffer .= $line;
            $self->process_buffer();
        }

        # Clean up when done
        $logger->log("Server shutting down...");
    }

    method process_buffer {

        # Process line-by-line (each message is on a separate line)
        while ( $buffer =~ s/^(.*)\n// ) {
            my $line = $1;
            next unless $line =~ /\S/;    # Skip empty lines

            $logger->log( "Received message: $line", 'debug' );

            try {
                my $message = decode_json($line);
                $self->handle_message($message);
            }
            catch ($e) {
                $logger->log( "Parse error: $e", 'error' );
                $self->send_error( -32700, "Parse error", undef );
            }
        }
    }

    method handle_message ($message) {

        # Validate JSON-RPC version
        if ( !exists $message->{jsonrpc} || $message->{jsonrpc} ne "2.0" ) {
            $self->send_error( -32600, "Invalid Request", $message->{id} );
            return;
        }

        # Handle request
        if ( exists $message->{method} ) {
            $self->handle_request($message);
        }

        # We're not expecting responses in this simple server
        elsif ( exists $message->{result} || exists $message->{error} ) {

            # Would handle responses here in a more complex implementation
            $logger->log( "Received response/error message (not handling)",
                'debug' );
        }

        # Invalid message
        else {
            $logger->log( "Invalid message format", 'error' );
            $self->send_error( -32600, "Invalid Request", $message->{id} );
        }
    }

    method handle_request ($request) {
        my $method = $request->{method};
        $logger->log("Handling request method: $method");

        if ( $method eq "initialize" ) {
            $self->handle_initialize($request);
        }
        elsif ( $method eq "initialized" ) {
            $logger->log("Received 'initialized' notification");

            # No response needed for notifications
        }
        elsif ( $method eq "tools/list" ) {
            $self->handle_list_tools($request);
        }
        elsif ( $method eq "tools/call" ) {
            $self->handle_call_tool($request);
        }
        elsif ( $method eq "shutdown" ) {
            $self->handle_shutdown($request);
        }
        elsif ( $method eq "exit" ) {
            $logger->log("Received exit notification");

            # No response needed for notifications
            exit(0);
        }
        else {
            $logger->log( "Method not found: $method", 'error' );
            $self->send_error( -32601, "Method not found: $method",
                $request->{id} );
        }
    }

    method handle_initialize ($request) {
        $logger->log("Handling initialize request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                protocolVersion => $PROTOCOL_VERSION,
                serverInfo      => {
                    name    => $SERVER_NAME,
                    version => $SERVER_VERSION
                },
                capabilities => {
                    tools => { listChanged => true }
                }
            }
        };

        $self->send_message($response);

        # Send initialized notification right after initialization
        my $notification = {
            jsonrpc => "2.0",
            method  => "initialized",
            params  => {}
        };

        $self->send_message($notification);
    }

    method handle_list_tools ($request) {
        $logger->log("Handling tools/list request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                tools => [
                    {
                        name        => "search_modules",
                        description =>
"Search for Perl modules based on keywords or criteria",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                query => {
                                    type        => "string",
                                    description => "Search term or keywords"
                                },
                                size => {
                                    type        => "integer",
                                    description =>
                                      "Number of results to return",
                                    default => $config->max_results
                                }
                            },
                            required => ["query"]
                        }
                    },
                    {
                        name        => "module_info",
                        description =>
"Get detailed information about a specific Perl module",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                module => {
                                    type        => "string",
                                    description =>
"Module name (e.g., 'Moose', 'Path::Tiny')"
                                }
                            },
                            required => ["module"]
                        }
                    },
                    {
                        name        => "get_documentation",
                        description =>
                          "Retrieve documentation for a Perl module",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                module => {
                                    type        => "string",
                                    description =>
"Module name (e.g., 'Moose', 'Path::Tiny')"
                                },
                                section => {
                                    type        => "string",
                                    description =>
"Documentation section to retrieve (e.g., 'SYNOPSIS', 'METHODS')",
                                    default => "all"
                                }
                            },
                            required => ["module"]
                        }
                    },
                    {
                        name        => "analyze_dependencies",
                        description =>
                          "Analyze dependencies for a specific Perl module",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                module => {
                                    type        => "string",
                                    description =>
"Module name (e.g., 'Moose', 'Path::Tiny')"
                                }
                            },
                            required => ["module"]
                        }
                    },
                    {
                        name        => "author_info",
                        description => "Get information about a CPAN author",
                        inputSchema => {
                            type       => "object",
                            properties => {
                                author => {
                                    type        => "string",
                                    description =>
"Author PAUSE ID (e.g., 'MIYAGAWA', 'RJBS')"
                                }
                            },
                            required => ["author"]
                        }
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method handle_call_tool ($request) {
        $logger->log("Handling tools/call request");

        my $tool_name = $request->{params}{name}      // '';
        my $tool_args = $request->{params}{arguments} // {};

        $logger->log( "Tool: $tool_name, Arguments: " . encode_json($tool_args),
            'debug' );

        my $result;
        my $is_error = false;

        try {
            if ( $tool_name eq "search_modules" ) {
                $result = $module_search_tool->execute($tool_args);
            }
            elsif ( $tool_name eq "module_info" ) {
                $result = $module_info_tool->execute($tool_args);
            }
            elsif ( $tool_name eq "get_documentation" ) {
                $result = $documentation_tool->execute($tool_args);
            }
            elsif ( $tool_name eq "analyze_dependencies" ) {
                $result = $dependency_tool->execute($tool_args);
            }
            elsif ( $tool_name eq "author_info" ) {
                $result = $author_info_tool->execute($tool_args);
            }
            else {
                $is_error = true;
                $result   = { content => "Tool not found: $tool_name" };
                $logger->log( "Tool not found: $tool_name", 'error' );
            }
        }
        catch ($e) {
            $is_error = true;
            $result   = { content => "Error executing tool: $e" };
            $logger->log( "Error executing tool: $e", 'error' );
        }

        # Check if we got an error result from the tool
        if ( ref($result) eq 'HASH' && $result->{is_error} ) {
            $is_error = true;
        }

        # Format response
        my $content = [];
        if ( ref($result) eq 'HASH' && ref( $result->{content} ) eq 'ARRAY' ) {
            $content = $result->{content};
        }
        elsif ( ref($result) eq 'HASH' && $result->{content} ) {
            $content = [ { type => "text", text => $result->{content} } ];
        }
        else {
            $content = [ { type => "text", text => "Unknown result format" } ];
        }

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                isError => $is_error ? true : false,
                content => $content
            }
        };

        $self->send_message($response);
    }

    method handle_shutdown ($request) {
        $logger->log("Received shutdown request");

        # Handle shutdown request properly with empty result object
        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {}
        };

        $self->send_message($response);

        # Exit after sending response
        exit(0);
    }

    # Send a JSON-RPC message
    method send_message ($message) {
        my $message_json = encode_json($message);
        $logger->log( "Sending message: $message_json", 'debug' );
        say $message_json;
    }

    # Send a JSON-RPC error
    method send_error ( $code, $message, $id ) {
        $logger->log( "Sending error: $message (code: $code)", 'error' );

        my $error = {
            jsonrpc => "2.0",
            id      => 0 + $id,    # Ensure ID is not null
            error   => {
                code    => $code,
                message => $message
            }
        };

        $self->send_message($error);
    }

    # Send a logging notification to the client
    method send_log_notification ( $level, $message ) {
        my $notification = {
            jsonrpc => "2.0",
            method  => "notifications/logging/message",
            params  => {
                level => $level,    # "debug", "info", "warning", "error"
                data  => $message
            }
        };

        $self->send_message($notification);
    }
}

# Create and run server
my $config = Config->new();
my $server = MCPServer->new( config => $config );
$server->run();

__END__

=head1 NAME

metacpan-server.pl - MCP server providing access to the MetaCPAN API

=head1 DESCRIPTION

An MCP (Model Context Protocol) server that provides tools for accessing the
MetaCPAN API, allowing AI assistants to retrieve accurate information about
Perl modules, authors, and related resources.

=head1 USAGE

  ./metacpan-server.pl [options]

  Environment Variables:
    METACPAN_API_URL     Base URL for the MetaCPAN API (default: https://fastapi.metacpan.org/v1)
    DEBUG                Enable debug output (default: 0)
    LOG_FILE             Path to log file
    CACHE_TTL            Time-to-live for cached results in seconds (default: 3600)
    MAX_RESULTS          Maximum results to return for searches (default: 10)
    TIMEOUT              Timeout for API requests in seconds (default: 10)

=head1 INTEGRATION WITH CLAUDE DESKTOP

To integrate with Claude Desktop:

1. Edit the Claude Desktop configuration file:
   ~/Library/Application Support/Claude/claude_desktop_config.json (Mac)
   %AppData%\Claude\claude_desktop_config.json (Windows)

2. Add your server configuration:
   {
     "mcpServers": {
       "metacpan": {
         "command": "perl",
         "args": [
           "/path/to/metacpan-server.pl"
         ],
         "env": {
           "METACPAN_API_URL": "https://fastapi.metacpan.org/v1",
         }
       }
     }
   }

3. Restart Claude Desktop

=head1 AVAILABLE TOOLS

This server provides five main tools:

1. search_modules - Search for Perl modules based on keywords
2. module_info - Get detailed information about a specific module
3. get_documentation - Retrieve documentation for a module
4. analyze_dependencies - Analyze dependencies for a module
5. author_info - Get information about a CPAN author

=head1 AUTHORS

The MetaCPAN MCP Server was created to enhance AI assistant capabilities
for Perl development workflows.

=cut
