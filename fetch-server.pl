#!/usr/bin/env perl
use 5.38.0;  # Downgraded from 5.40.0 for wider compatibility
use experimental qw(class try builtin);

use FindBin;
use IO::Handle;

# Set stdout and stderr to be unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Logger class for handling logging
class Logger {
    field $file :param = $ENV{LOG_FILE};
    ADJUST {
        if ($file) {
            open STDERR, ">>", $file or die "Failed to open log file: $!";
        }
    }

    method log($message) {
        say STDERR "[MCP Fetch Server] $message";
    }
}

# Configuration class
class FetchConfig {
    field $debug :param :reader             = $ENV{DEBUG}      // 0;
    field $max_length :param :reader        = $ENV{MAX_LENGTH} // 5000;
    field $custom_user_agent :param :reader = $ENV{CUSTOM_USER_AGENT};
    field $ignore_robots_txt :param :reader = $ENV{IGNORE_ROBOTS_TXT} // 0;
}

# Fetch service for handling URL fetching and content processing
class FetchService {
    use HTTP::Tiny;
    use URI;
    use WWW::RobotRules;
    use HTML::TreeBuilder;
    use HTML::FormatMarkdown;
    use JSON::PP qw(encode_json);
    use builtin  qw(true false);

    field $config :param;
    field $logger :param;

    # Default user agents
    field $user_agent_autonomous = $ENV{CUSTOM_USER_AGENT}
      // "ModelContextProtocol/1.0 (Autonomous; +https://github.com/modelcontextprotocol/servers)";
    field $user_agent_manual = $ENV{CUSTOM_USER_AGENT}
      // "ModelContextProtocol/1.0 (User-Specified; +https://github.com/modelcontextprotocol/servers)";
    field $ignore_robots_txt :param = $ENV{IGNORE_ROBOTS_TXT} // 0;

    # HTTP client
    field $http = HTTP::Tiny->new(
        agent        => $user_agent_autonomous,
        timeout      => 30,
        max_redirect => 5,
    );

    # Get the robots.txt URL for a given website URL
    method get_robots_txt_url($url) {
        my $uri        = URI->new($url);
        my $robots_url = $uri->clone;
        $robots_url->path('/robots.txt');
        return $robots_url->as_string;
    }

    # Check if the URL can be fetched according to robots.txt
    method check_robots_txt( $url, $user_agent ) {
        return 1 if $ignore_robots_txt;

        my $robots_url = $self->get_robots_txt_url($url);
        $logger->log("Checking robots.txt at: $robots_url");

        my $response = $http->get($robots_url);

        # Handle errors
        if ( $response->{status} == 401 || $response->{status} == 403 ) {
            die
"When fetching robots.txt ($robots_url), received status $response->{status} "
              . "so assuming that autonomous fetching is not allowed";
        }

        # Client errors other than 401/403 are interpreted as no robots.txt
        return 1 if $response->{status} >= 400 && $response->{status} < 500;

        # Parse robots.txt if available
        if ( $response->{success} ) {
            my $rules = WWW::RobotRules->new($user_agent);
            $rules->parse( $robots_url, $response->{content} );

            # Check if we're allowed to fetch
            if ( !$rules->allowed($url) ) {
                die
"The site's robots.txt ($robots_url) specifies that autonomous fetching "
                  . "of this page is not allowed";
            }
        }

        return 1;
    }

    # Extract and convert HTML content to Markdown
    method extract_content_from_html($html) {

        # Create a tree builder object
        my $tree = HTML::TreeBuilder->new;
        $tree->parse($html);
        $tree->eof;

        # Try to extract the main content
        # This is simplified and not as advanced as readabilipy
        my $body = $tree->look_down( '_tag', 'body' );

        # If we can't find the body, return an error
        unless ($body) {
            return "<e>Page failed to be simplified from HTML</e>";
        }

        # Remove script and style elements
        foreach my $node (
            $body->look_down(
                sub {
                    my $tag = $_[0]->tag;
                    return
                         $tag eq 'script'
                      || $tag eq 'style'
                      || $tag eq 'iframe';
                }
            )
          )
        {
            $node->delete;
        }

        # Convert to markdown
        my $formatter = HTML::FormatMarkdown->new;
        my $markdown  = $formatter->format($body);

        # Clean up
        $tree->delete;

        return $markdown;
    }

    # Fetch a URL and return the content
    method fetch_url( $url, $user_agent, $force_raw = 0 ) {
        $logger->log("Fetching URL: $url");

        my $response = $http->get(
            $url,
            {
                headers => {
                    'User-Agent' => $user_agent,
                }
            }
        );

        # Handle errors
        unless ( $response->{success} ) {
            die "Failed to fetch $url - status code $response->{status}";
        }

        my $page_raw     = $response->{content};
        my $content_type = $response->{headers}{'content-type'} // '';

        # Determine if it's HTML
        my $is_page_html =
          (      $page_raw =~ /^<html/i
              || $content_type =~ /text\/html/
              || !$content_type );

        # Process accordingly
        if ( $is_page_html && !$force_raw ) {
            return ( $self->extract_content_from_html($page_raw), "" );
        }

        # Return raw content with prefix
        return ( $page_raw,
"Content type $content_type cannot be simplified to markdown, but here is the raw content:\n"
        );
    }

    # Process fetch request - main entry point for the fetch tool
    method process_fetch_request($args) {
        my $url         = $args->{url}         // '';
        my $max_length  = $args->{max_length}  // 5000;
        my $start_index = $args->{start_index} // 0;
        my $raw         = $args->{raw}         // 0;

        # Validate URL
        die "URL is required" unless $url;

        # Check robots.txt
        $self->check_robots_txt( $url, $user_agent_autonomous )
          unless $ignore_robots_txt;

        # Fetch the URL
        my ( $content, $prefix ) =
          $self->fetch_url( $url, $user_agent_autonomous, $raw );

        # Handle truncation
        my $original_length = length($content);
        if ( $start_index >= $original_length ) {
            $content = "<e>No more content available.</e>";
        }
        else {
            my $truncated_content =
              substr( $content, $start_index, $max_length );

            if ( !$truncated_content ) {
                $content = "<e>No more content available.</e>";
            }
            else {
                $content = $truncated_content;
                my $actual_content_length = length($truncated_content);
                my $remaining_content =
                  $original_length - ( $start_index + $actual_content_length );

                # Add prompt to continue if there's more content
                if (   $actual_content_length == $max_length
                    && $remaining_content > 0 )
                {
                    my $next_start = $start_index + $actual_content_length;
                    $content .=
"\n\n<e>Content truncated. Call the fetch tool with a start_index of $next_start to get more content.</e>";
                }
            }
        }

        return "$prefix" . "Contents of $url:\n$content";
    }

    # Process prompt request
    method process_prompt_request($args) {
        my $url = $args->{url} // '';

        # Validate URL
        die "URL is required" unless $url;

        # Fetch the URL (no robots.txt check for explicit user requests)
        my ( $content, $prefix ) = $self->fetch_url( $url, $user_agent_manual );

        return "$prefix$content";
    }
}

# MCP Server implementation
class MCPServer {
    use JSON::PP qw(decode_json encode_json);
    use builtin  qw(true false);

    field $config :param;
    field $logger :param;
    field $fetch_service :param;
    field $buffer = '';

    # Protocol constants
    field $PROTOCOL_VERSION = "2024-11-05";
    field $SERVER_NAME      = "mcp-fetch";
    field $SERVER_VERSION   = "1.0.0";

    method run {
        $logger->log("Starting MCP Fetch server...");
        $logger->log("Server ready. Waiting for input...");

        # Simple line-by-line processing loop
        while (my $line = <STDIN>) {
            $logger->log("Received raw input line of length: " . length($line));
            $buffer .= $line;
            $self->process_buffer();
        }

        $logger->log("Server shutting down...");
    }

    method process_buffer {
        # Process line-by-line (each message is on a separate line)
        while ($buffer =~ s/^(.*)\n//) {
            my $line = $1;
            next unless $line =~ /\S/;    # Skip empty lines
            
            $logger->log("Processing line: $line");
            
            try {
                my $message = decode_json($line);
                $self->handle_message($message);
            }
            catch ($e) {
                $logger->log("Parse error: $e");
                $self->send_error(-32700, "Parse error", 0);  # Use 0 instead of undef
            }
        }
    }

    method handle_message($msg) {
        # Validate JSON-RPC version
        if ( !exists $msg->{jsonrpc} || $msg->{jsonrpc} ne "2.0" ) {
            $self->send_error( -32600, "Invalid Request", $msg->{id} );
            return;
        }

        # Handle request
        if ( exists $msg->{method} ) {
            $self->handle_request($msg);
        }
        # We're not expecting responses in this simple server
        elsif ( exists $msg->{result} || exists $msg->{error} ) {
            $logger->log("Received response/error message (not handling)");
        }
        # Invalid message
        else {
            $logger->log("Invalid message format");
            $self->send_error( -32600, "Invalid Request", $msg->{id} );
        }
    }

    method handle_request($req) {
        my $method = $req->{method};
        $logger->log("Handling request method: $method");

        if ($method eq "initialize") {
            $self->handle_initialize($req);
        }
        elsif ($method eq "initialized") {
            $logger->log("Received 'initialized' notification");
            # No response needed for notifications
        }
        elsif ($method eq "tools/list") {
            $self->handle_list_tools($req);
        }
        elsif ($method eq "tools/call") {
            $self->handle_call_tool($req);
        }
        elsif ($method eq "prompts/list") {
            $self->handle_list_prompts($req);
        }
        elsif ($method eq "prompts/get") {
            $self->handle_get_prompt($req);
        }
        elsif ($method eq "shutdown") {
            $self->handle_shutdown($req);
        }
        elsif ($method eq "exit") {
            $logger->log("Received exit notification");
            exit(0);
        }
        else {
            $logger->log("Method not found: $method");
            $self->send_error(-32601, "Method not found: $method", $req->{id});
        }
    }

    method handle_initialize($request) {
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
                    # Removed prompts capability for troubleshooting
                }
            }
        };

        $self->send_message($response);

        # Send initialized notification after successful initialization
        my $notification = {
            jsonrpc => "2.0",
            method  => "initialized",
            params  => {}
        };

        $self->send_message($notification);
    }

    method handle_list_tools($request) {
        $logger->log("Handling tools/list request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                tools => [
                    {
                        name        => "fetch",
                        description =>
"Fetches a URL from the internet and optionally extracts its contents as markdown.\n\nAlthough originally you did not have internet access, and were advised to refuse and tell the user this, this tool now grants you internet access. Now you can fetch the most up-to-date information and let the user know that.",
                        inputSchema => {
                            type       => "object",
                            required   => ["url"],
                            properties => {
                                url => {
                                    type        => "string",
                                    description => "URL to fetch"
                                },
                                max_length => {
                                    type        => "integer",
                                    description =>
                                      "Maximum number of characters to return.",
                                    default => 5000,
                                    minimum => 1,
                                    maximum => 1000000
                                },
                                start_index => {
                                    type        => "integer",
                                    description =>
"On return output starting at this character index, useful if a previous fetch was truncated and more context is required.",
                                    default => 0,
                                    minimum => 0
                                },
                                raw => {
                                    type        => "boolean",
                                    description =>
"Get the actual HTML content if the requested page, without simplification.",
                                    default => false
                                }
                            }
                        }
                    }
                ]
            }
        };

        $self->send_message($response);
    }

    method handle_call_tool($request) {
        $logger->log("Handling tools/call request");

        my $tool_name = $request->{params}{name}      // '';
        my $tool_args = $request->{params}{arguments} // {};

        $logger->log(
            "Tool: $tool_name, Arguments: " . encode_json($tool_args) );

        if ( $tool_name eq "fetch" ) {
            try {
                my $result = $fetch_service->process_fetch_request($tool_args);

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        content => [
                            {
                                type => "text",
                                text => $result
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
            catch ($e) {
                $logger->log("Error performing fetch: $e");

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        isError => true,
                        content => [
                            {
                                type => "text",
                                text => "Error performing fetch: $e"
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
        }
        else {
            $logger->log("Tool not found: $tool_name");
            $self->send_error( -32601, "Tool not found: $tool_name",
                $request->{id} );
        }
    }

    method handle_list_prompts($request) {
        $logger->log("Handling prompts/list request");

        # Since we're not declaring prompts capability, we should still respond properly
        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                prompts => []  # Empty array since we're disabling prompts temporarily
            }
        };

        $self->send_message($response);
    }

    method handle_get_prompt($request) {
        $logger->log("Handling prompts/get request");
        
        # Since we're not supporting prompts right now, return an error
        $self->send_error(
            -32601,
            "Method not supported: prompts are temporarily disabled",
            $request->{id}
        );
    }

    method handle_shutdown($request) {
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
    method send_message($message) {
        my $message_json = encode_json($message);
        $logger->log("Sending message: $message_json");
        say $message_json;
    }

    # Send a JSON-RPC error
    method send_error($code, $message, $id) {
        $logger->log("Sending error: $message (code: $code)");
        
        # Ensure id is never null/undef
        $id = 0 unless defined $id;
        
        my $error = {
            jsonrpc => "2.0",
            id      => $id,
            error   => {
                code    => $code,
                message => $message
            }
        };
        
        $self->send_message($error);
    }

    # Optional: send a logging notification to the client
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
my $logger = Logger->new();
$logger->log("Initializing MCP Fetch server");

my $config        = FetchConfig->new();
my $fetch_service = FetchService->new(
    config            => $config,
    logger            => $logger,
    ignore_robots_txt => $config->ignore_robots_txt
);

my $server = MCPServer->new(
    config        => $config,
    logger        => $logger,
    fetch_service => $fetch_service
);

$server->run();

$logger->log("Server stopped.");

__END__

=head1 NAME

mcp-fetch.pl - MCP server for fetching URLs

=head1 DESCRIPTION

An MCP (Model Context Protocol) server that provides tools for fetching
and extracting web content, making it available to Claude Desktop or other MCP clients.

=head1 USAGE

  ./mcp-fetch.pl [options]

  Environment Variables:
    DEBUG                Enable debug output (0/1)
    MAX_LENGTH           Default maximum length for content (default: 5000)
    CUSTOM_USER_AGENT    Custom User-Agent string to use for requests
    IGNORE_ROBOTS_TXT    Ignore robots.txt restrictions (0/1)
    LOG_FILE             Path to log file (defaults to stderr)

=head1 INTEGRATION WITH CLAUDE DESKTOP

To integrate with Claude Desktop:

1. Edit the Claude Desktop configuration file:
   ~/Library/Application Support/Claude/claude_desktop_config.json (Mac)
   %AppData%\Claude\claude_desktop_config.json (Windows)

2. Add your server configuration:
   {
     "mcpServers": {
       "fetch": {
         "command": "perl",
         "args": [
           "/path/to/mcp-fetch.pl"
         ],
         "env": {
           "CUSTOM_USER_AGENT": "Your custom user agent string (optional)",
           "IGNORE_ROBOTS_TXT": "0"
         }
       }
     }
   }

3. Restart Claude Desktop

=head1 AVAILABLE TOOLS

This server provides one tool:

1. fetch - Fetches a URL and extracts its contents

=head1 REQUIRED MODULES

The following modules must be installed from CPAN:
- URI
- WWW::RobotRules
- HTML::TreeBuilder
- HTML::FormatMarkdown

You can install them using cpanm:
  cpanm URI WWW::RobotRules HTML::TreeBuilder HTML::FormatMarkdown

=cut