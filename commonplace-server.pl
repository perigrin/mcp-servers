#!/usr/bin/env perl
use 5.38.0;
use experimental qw(class try builtin);

use FindBin;
use local::lib "$FindBin::Bin/../local";
use DBI;
use DBD::SQLite;
use IO::Handle;

$ENV{DB_PATH} //= "$FindBin::Bin/../commonplace.db";

# Set stdout and stderr to be unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Protocol constants
my $PROTOCOL_VERSION = "2024-11-05";
my $SERVER_NAME      = "commonplace";
my $SERVER_VERSION   = "1.0.0";

# MCP Server implementation for Commonplace knowledge base
# This server implements the Model Context Protocol to provide
# search capabilities for your personal knowledge base in Claude Desktop

class Logger {
    field $file :param = $ENV{LOG_FILE};
    ADJUST {
        if ($file) {
            open STDERR, ">>", $file or die "Failed to open log file: $!";
        }
    }

    method log ($message) {
        say STDERR "[MCP Server] $message";
    }
}

# Configuration class
class Config {
    field $db_path :param :reader     = $ENV{DB_PATH};
    field $debug :param :reader       = 0;
    field $max_results :param :reader = 5;
}

# Database class (adapted from indexer.pl)
class Database {
    field $dbh;
    field $config :param;
    field $logger = Logger->new();

    ADJUST {
        my $db_path = $config->db_path;

        unless ( -e $db_path ) {
            die "Database file not found: $db_path";
        }

        $logger->log("Connecting to database: $db_path");
        $dbh = DBI->connect(
            "dbi:SQLite:dbname=$db_path",
            "", "",
            {
                RaiseError => 1,
                PrintError => 0,
                AutoCommit => 1,
            }
        );
        $logger->log("Database connection established");
    }

    method search ( $query, $limit = 5 ) {
        $logger->log("Performing keyword search for: $query (limit: $limit)");

        # Keyword-based search using FTS
        my $sth = $dbh->prepare(
            q{
            SELECT id,
                   title,
                   path,
                   snippet(documents_fts, 1, '<b>', '</b>', '...', 15) as snippet,
                   content
            FROM documents_fts
            WHERE documents_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        }
        );
        $sth->execute( $query, $limit );

        my @results;
        while ( my $row = $sth->fetchrow_hashref ) {

            # Truncate content if needed
            my $max_content = 1000;    # Maximum characters to include
            if ( length( $row->{content} ) > $max_content ) {
                $row->{content} =
                  substr( $row->{content}, 0, $max_content ) . "...";
            }

            push @results, $row;
        }

        $logger->log( "Search found " . scalar(@results) . " results" );
        return \@results;
    }

    method semantic_search ( $query, $limit = 5 ) {
        $logger->log("Performing semantic search for: $query (limit: $limit)");

        # We need to embed the query first
        # For now, we'll use a simplified approach by importing the
        # EmbeddingService from indexer.pl

        # Import and instantiate indexer's EmbeddingService
        require './indexer.pl';    # Assumes indexer.pl is in the same directory

        my $embedding_service = EmbeddingService->new( config => $config );
        my $query_embedding =
          $embedding_service->get_embedding_for_text( $query, 'query' );

        # Now search for similar documents
        return $self->search_similar( $query_embedding, $limit );
    }

    method search_similar ( $query_embedding, $limit = 5 ) {
        $logger->log("Finding similar documents");

        # Fetch all embeddings
        my $sth = $dbh->prepare(
            q{
            SELECT e.document_id,
                   e.chunk_index,
                   e.chunk_text,
                   e.embedding,
                   d.title,
                   d.path,
                   d.content
            FROM embeddings e
            JOIN documents d ON e.document_id = d.id
        }
        );
        $sth->execute();

        my @results;
        while ( my $row = $sth->fetchrow_hashref ) {
            my $embedding = $row->{embedding};
            my $similarity =
              $self->cosine_similarity( $query_embedding, $embedding );

            # Truncate content if needed
            my $max_content = 1000;    # Maximum characters to include
            if ( length( $row->{content} ) > $max_content ) {
                $row->{content} =
                  substr( $row->{content}, 0, $max_content ) . "...";
            }

            push @results,
              {
                document_id => $row->{document_id},
                chunk_index => $row->{chunk_index},
                chunk_text  => $row->{chunk_text},
                title       => $row->{title},
                path        => $row->{path},
                content     => $row->{content},
                similarity  => $similarity
              };
        }

        # Sort by similarity (highest first)
        my @sorted_results =
          sort { $b->{similarity} <=> $a->{similarity} } @results;

        # Return top results
        my $final_results = [
            @sorted_results[
              0 .. (
                  $limit - 1 < $#sorted_results ? $limit - 1 : $#sorted_results
              )
            ]
        ];

        $logger->log(
            "Found " . scalar(@$final_results) . " similar documents" );
        return $final_results;
    }

    method cosine_similarity ( $embedding1, $embedding2 ) {
        my @vec1 = unpack( "f*", $embedding1 );
        my @vec2 = unpack( "f*", $embedding2 );

        my $dot_product = 0;
        my $norm1       = 0;
        my $norm2       = 0;

        for ( my $i = 0 ; $i < @vec1 ; $i++ ) {
            $dot_product += $vec1[$i] * $vec2[$i];
            $norm1       += $vec1[$i] * $vec1[$i];
            $norm2       += $vec2[$i] * $vec2[$i];
        }

        $norm1 = sqrt($norm1);
        $norm2 = sqrt($norm2);

        return $dot_product / ( $norm1 * $norm2 );
    }

    method disconnect {
        $logger->log("Disconnecting from database");
        $dbh->disconnect if $dbh;
    }
}

class MCPServer {
    use JSON::PP qw(decode_json encode_json);
    use builtin  qw(true);
    field $config :param;
    field $database = Database->new( config => $config );
    field $logger   = Logger->new();
    field $buffer   = '';

    method run {
        $logger->log("Starting Commonplace MCP server...");
        $logger->log("Server ready. Waiting for input...");

        # Simple line-by-line processing loop
        while ( my $line = <STDIN> ) {
            $buffer .= $line;
            $self->process_buffer();
        }

        # Clean up when done
        $logger->log("Server shutting down...");
        $database->disconnect();
    }

    method process_buffer {

        # Process line-by-line (each message is on a separate line)
        while ( $buffer =~ s/^(.*)\n// ) {
            my $line = $1;
            next unless $line =~ /\S/;    # Skip empty lines

            $logger->log("Received message: $line");

            try {
                my $message = decode_json($line);
                $self->handle_message($message);
            }
            catch ($e) {
                $logger->log("Parse error: $e");
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
            $logger->log("Received response/error message (not handling)");
        }

        # Invalid message
        else {
            $logger->log("Invalid message format");
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
            $logger->log("Method not found: $method");
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
                    tools     => { listChanged => true }
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
                        name        => "keyword_search",
                        description =>
                          "Search your personal knowledge base using keywords",
                        inputSchema => {
                            type       => "object",
                            required   => ["query"],
                            properties => {
                                query => {
                                    type        => "string",
                                    description => "The search query"
                                },
                                limit => {
                                    type        => "integer",
                                    description =>
                                      "Maximum number of results to return",
                                    default => $config->max_results
                                }
                            }
                        }
                    },
                    {
                        name        => "semantic_search",
                        description =>
"Search your personal knowledge base using semantic similarity",
                        inputSchema => {
                            type       => "object",
                            required   => ["query"],
                            properties => {
                                query => {
                                    type        => "string",
                                    description => "The search query"
                                },
                                limit => {
                                    type        => "integer",
                                    description =>
                                      "Maximum number of results to return",
                                    default => $config->max_results
                                }
                            }
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

        $logger->log(
            "Tool: $tool_name, Arguments: " . encode_json($tool_args) );

        if ( $tool_name eq "keyword_search" ) {
            my $query = $tool_args->{query} // '';
            my $limit = $tool_args->{limit} // $config->max_results;

            try {
                my $results = $database->search( $query, $limit );

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        content => [
                            {
                                type => "text",
                                text => $self->format_search_results(
                                    $results, $query
                                )
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
            catch ($e) {
                $logger->log("Error performing keyword search: $e");

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        isError => true,
                        content => [
                            {
                                type => "text",
                                text => "Error performing search: $e"
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
        }
        elsif ( $tool_name eq "semantic_search" ) {
            $logger->log("Running semantic_search");
            my $query = $tool_args->{query} // '';
            my $limit = $tool_args->{limit} // $config->max_results;

            try {
                my $results = $database->semantic_search( $query, $limit );

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        content => [
                            {
                                type => "text",
                                text => $self->format_search_results(
                                    $results, $query
                                )
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
            catch ($e) {
                $logger->log("Error performing semantic search: $e");

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        isError => true,
                        content => [
                            {
                                type => "text",
                                text => "Error performing search: $e"
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

    method format_search_results ( $results, $query ) {
        my $output = "Results for query: \"$query\"\n\n";

        if ( @$results == 0 ) {
            return $output . "No results found.";
        }

        foreach my $result (@$results) {
            $output .= "# " .     ( $result->{title} || "Untitled" ) . "\n";
            $output .= "Path: " . ( $result->{path}  || "Unknown" ) . "\n";

            if ( defined $result->{similarity} ) {
                $output .= "Relevance: "
                  . sprintf( "%.2f%%", $result->{similarity} * 100 ) . "\n";
            }

            if ( defined $result->{snippet} ) {
                $output .= "Snippet: " . $result->{snippet} . "\n";
            }

            $output .= "\n"
              . ( $result->{chunk_text} || $result->{content} || "" ) . "\n\n";
            $output .= "---\n\n";
        }

        return $output;
    }

    # Send a JSON-RPC message
    method send_message ($message) {
        my $message_json = encode_json($message);
        $logger->log("Sending message: $message_json");
        say $message_json;
    }

    # Send a JSON-RPC error
    method send_error ( $code, $message, $id ) {
        $logger->log("Sending error: $message (code: $code)");

        my $error = {
            jsonrpc => "2.0",
            id      => 0 + $id,
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
my $config = Config->new();

my $server = MCPServer->new( config => $config );
$server->run();
say STDERR "Server stopped.";
__END__

=head1 NAME

commonplace-mcp.pl - MCP server for searching Commonplace knowledge base

=head1 DESCRIPTION

An MCP (Model Context Protocol) server that provides tools for searching
a personal knowledge base (commonplace.db) from Claude Desktop.

=head1 USAGE

  ./commonplace-mcp.pl [options]

  Options:
    --db=PATH        Path to SQLite database (default: commonplace.db)
    --debug          Enable debug output to stderr

=head1 INTEGRATION WITH CLAUDE DESKTOP

To integrate with Claude Desktop:

1. Edit the Claude Desktop configuration file:
   ~/Library/Application Support/Claude/claude_desktop_config.json (Mac)
   %AppData%\Claude\claude_desktop_config.json (Windows)

2. Add your server configuration:
   {
     "mcpServers": {
       "commonplace": {
         "command": "perl",
         "args": [
           "/path/to/commonplace-mcp.pl",
           "--db=/path/to/commonplace.db"
         ]
       }
     }
   }

3. Restart Claude Desktop

=head1 AVAILABLE TOOLS

This server provides two tools:

1. keyword_search - Traditional text search in your knowledge base
2. semantic_search - Search using semantic similarity (vector search)

=cut
