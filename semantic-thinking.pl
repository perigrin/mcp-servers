#!/usr/bin/env perl
use 5.40.0;
use experimental qw(class try builtin);
use lib::xi;

use IO::Handle;
use JSON::PP;
use DBI;
use DBD::SQLite;
use HTTP::Tiny;
use Data::UUID;
use MIME::Base64;
use Log::Log4perl::Tiny qw(:easy);

# Constants
our $PROTOCOL_VERSION = "2024-11-05";
our $SERVER_NAME      = "semantic-sequential-thinking";
our $SERVER_VERSION   = "1.0.0";

# Set stdout and stderr to be unbuffered
STDOUT->autoflush(1);
STDERR->autoflush(1);

# Set format to include [MCP Server] prefix
Log::Log4perl->easy_init(
    {
        layout => '[MCP Server] %m%n',
        level  => $ENV{DEBUG} ? $DEBUG : $INFO,
        ( $ENV{LOG_FILE} ? ( file => $ENV{LOG_FILE} ) : () )
    }
);

# Configuration class
class SemanticThinkingConfig {

    # Database settings
    field $dsn :param :reader = $ENV{DATABASE_DSN}
      // 'dbi:SQLite:dbname=semantic_thinking.db';
    field $db_user :param :reader     = $ENV{DATABASE_USER}     // '';
    field $db_password :param :reader = $ENV{DATABASE_PASSWORD} // '';

    # Embedding settings
    field $voyage_api_key :param :reader  = $ENV{VOYAGE_API_KEY}  // '';
    field $embedding_model :param :reader = $ENV{EMBEDDING_MODEL} // 'voyage-3';
    field $embedding_dimensions :param :reader = $ENV{EMBEDDING_DIMENSIONS}
      // 1536;    # Default for voyage-3

    # Logging settings
    field $log_level :param :reader = $ENV{LOG_LEVEL} // 'info';
    field $log_file :param :reader  = $ENV{LOG_FILE};
    field $debug :param :reader     = $ENV{DEBUG} ? 1 : 0;

    # Query settings
    field $similarity_threshold :param :reader = $ENV{SIMILARITY_THRESHOLD}
      // 0.7;

    # Server settings
    field $server_name :param :reader = $ENV{SERVER_NAME}
      // 'semantic-sequential-thinking';
    field $server_version :param :reader = $ENV{SERVER_VERSION} // '1.0.0';

    # Detect database type
    method is_postgres {
        return $dsn =~ /^dbi:Pg:/i;
    }
}

# EmbeddingService for semantic analysis
class EmbeddingService {
    field $config :param;
    field $logger = main::get_logger();
    field $http   = HTTP::Tiny->new(
        timeout => 30,
        agent   => 'SemanticSequentialThinking/1.0'
    );

    method get_embedding_for_text( $text, $input_type = 'document' ) {
        $logger->log(
            "Getting embedding for text: " . substr( $text, 0, 100 ) . "...",
            'debug' );

        unless ( $config->voyage_api_key ) {
            $logger->warn("No Voyage API key configured, skipping embeddings");
            return undef;
        }

        # Truncate text if needed - Voyage limit is around 8192 tokens
        my $max_chars = 32000;    # Rough approximation
        if ( length($text) > $max_chars ) {
            $logger->warn("Text too long, truncating to $max_chars chars");
            $text = substr( $text, 0, $max_chars );
        }

        my $response = $http->post(
            "https://api.voyageai.com/v1/embeddings",
            {
                headers => {
                    'Content-Type'  => 'application/json',
                    'Authorization' => "Bearer " . $config->voyage_api_key
                },
                content => encode_json(
                    {
                        model      => $config->embedding_model,
                        input      => $text,
                        input_type => $input_type,
                    }
                )
            }
        );

        if ( $response->{success} ) {
            my $data = decode_json( $response->{content} );
            if (   exists $data->{data}
                && exists $data->{data}[0]
                && exists $data->{data}[0]{embedding} )
            {
                my $embedding = $data->{data}[0]{embedding};

               # Pack embedding as binary data for SQLite
               # For PostgreSQL, this will be unpacked and formatted as a vector
                return pack( "f*", @$embedding );
            }
        }

        $logger->error( "Failed to get embedding: " . $response->{content} );
        return undef;
    }

    method get_embeddings_for_texts( $texts, $input_type = 'document' ) {
        $logger->debug(
            "Getting embeddings for " . scalar(@$texts) . " texts" );

        my @embeddings;
        foreach my $text (@$texts) {
            push @embeddings,
              $self->get_embedding_for_text( $text, $input_type );
        }

        return \@embeddings;
    }

    # Calculate cosine similarity between two embeddings
    method cosine_similarity( $embedding1, $embedding2 ) {
        return 0 unless $embedding1 && $embedding2;

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

    # Find the most similar embedding in a list
    method find_most_similar( $embedding, $embedding_list ) {
        my $max_similarity     = -1;
        my $most_similar_index = -1;

        for ( my $i = 0 ; $i < @$embedding_list ; $i++ ) {
            next unless $embedding_list->[$i];
            my $similarity =
              $self->cosine_similarity( $embedding, $embedding_list->[$i] );
            if ( $similarity > $max_similarity ) {
                $max_similarity     = $similarity;
                $most_similar_index = $i;
            }
        }

        return {
            index      => $most_similar_index,
            similarity => $max_similarity
        };
    }

    # Calculate distance between embeddings (alternative to similarity)
    method euclidean_distance( $embedding1, $embedding2 ) {
        return undef unless $embedding1 && $embedding2;

        my @vec1 = unpack( "f*", $embedding1 );
        my @vec2 = unpack( "f*", $embedding2 );

        my $sum_squared_diff = 0;
        for ( my $i = 0 ; $i < @vec1 ; $i++ ) {
            my $diff = $vec1[$i] - $vec2[$i];
            $sum_squared_diff += $diff * $diff;
        }

        return sqrt($sum_squared_diff);
    }
}

# ThoughtStore for storing and retrieving thoughts
class ThoughtStore {
    field $config :param;
    field $logger = main::get_logger();
    field $dbh    = DBI->connect(
        $config->dsn,
        $config->db_user,
        $config->db_password,
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        }
    );
    field $embedding_service = EmbeddingService->new( config => $config );
    field $uuid_generator    = Data::UUID->new();
    field $is_postgres       = $config->is_postgres;

    ADJUST {
        $self->init_database();
    }

    method init_database {
        $logger->info("Initializing database schema");

        if ($is_postgres) {

            # PostgreSQL with pg_vector setup

            # Create vector extension if it doesn't exist
            $dbh->do("CREATE EXTENSION IF NOT EXISTS vector");

            # Create conversations table
            $dbh->do(
                q{
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY,
                    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                    updated_at TIMESTAMP WITH TIME ZONE NOT NULL
                )
            }
            );

            # Check if thoughts table exists
            my $table_exists = $dbh->selectrow_array(
"SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'thoughts')"
            );

            unless ($table_exists) {

                # Create thoughts table with vector type for embeddings
                $dbh->do(
                    qq{
                    CREATE TABLE thoughts (
                        id TEXT PRIMARY KEY,
                        conversation_id TEXT NOT NULL,
                        thought_number INTEGER NOT NULL,
                        thought TEXT NOT NULL,
                        embedding vector($config->embedding_dimensions),
                        branch_id TEXT,
                        branch_from_thought INTEGER,
                        is_revision BOOLEAN DEFAULT FALSE,
                        revises_thought INTEGER,
                        created_at TIMESTAMP WITH TIME ZONE NOT NULL,
                        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
                    )
                }
                );

                # Create indexes
                $dbh->do(
"CREATE INDEX idx_thoughts_conversation ON thoughts(conversation_id)"
                );
                $dbh->do(
                    "CREATE INDEX idx_thoughts_branch ON thoughts(branch_id)");
                $dbh->do(
"CREATE INDEX idx_thoughts_thought_number ON thoughts(thought_number)"
                );

# Create vector similarity index
# Using an HNSW index which is generally faster than ivfflat for exact nearest neighbor searches
# with a reasonable number of results
                $dbh->do(
                    qq{
                    CREATE INDEX idx_thoughts_embedding ON thoughts
                    USING hnsw (embedding vector_cosine_ops)
                    WITH (m = 16, ef_construction = 64)
                }
                );
            }
        }
        else {
            # SQLite setup
            $dbh->do(
                q{
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            }
            );

            $dbh->do(
                q{
                CREATE TABLE IF NOT EXISTS thoughts (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    thought_number INTEGER NOT NULL,
                    thought TEXT NOT NULL,
                    embedding BLOB,
                    branch_id TEXT,
                    branch_from_thought INTEGER,
                    is_revision BOOLEAN DEFAULT 0,
                    revises_thought INTEGER,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
                )
            }
            );

            $dbh->do(
                q{
                CREATE INDEX IF NOT EXISTS idx_thoughts_conversation
                ON thoughts(conversation_id)
            }
            );

            $dbh->do(
                q{
                CREATE INDEX IF NOT EXISTS idx_thoughts_branch
                ON thoughts(branch_id)
            }
            );

            $dbh->do(
                q{
                CREATE INDEX IF NOT EXISTS idx_thoughts_thought_number
                ON thoughts(thought_number)
            }
            );
        }
    }

    method create_conversation {
        my $id = $uuid_generator->create_str();

        if ($is_postgres) {

            # Use NOW() for PostgreSQL timestamps with timezone
            $dbh->do(
"INSERT INTO conversations (id, created_at, updated_at) VALUES (?, NOW(), NOW())",
                undef, $id
            );
        }
        else {
            # Use Unix timestamps for SQLite
            my $now = time();
            $dbh->do(
"INSERT INTO conversations (id, created_at, updated_at) VALUES (?, ?, ?)",
                undef, $id, $now, $now
            );
        }

        $logger->debug("Created new conversation with ID: $id");
        return $id;
    }

    method store_thought( $conversation_id, $thought_data ) {
        my $id  = $uuid_generator->create_str();
        my $now = time();

        # Get embedding for the thought
        my $embedding =
          $embedding_service->get_embedding_for_text( $thought_data->{thought},
            'document' );

        # Update conversation timestamp
        if ($is_postgres) {
            $dbh->do(
                "UPDATE conversations SET updated_at = NOW() WHERE id = ?",
                undef, $conversation_id );
        }
        else {
            $dbh->do( "UPDATE conversations SET updated_at = ? WHERE id = ?",
                undef, $now, $conversation_id );
        }

        # Insert the thought
        if ($is_postgres) {

            # Better handling for PostgreSQL with vector extension
            my $stmt = qq{
                INSERT INTO thoughts (
                    id, conversation_id, thought_number, thought, embedding,
                    branch_id, branch_from_thought, is_revision, revises_thought, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
            };

            if ($embedding) {

                # Convert to PostgreSQL vector format
                my @vec_values = unpack( "f*", $embedding );
                my $vec_string = '[' . join( ',', @vec_values ) . ']';

                $dbh->do(
                    $stmt,
                    undef,
                    $id,
                    $conversation_id,
                    $thought_data->{thoughtNumber},
                    $thought_data->{thought},
                    $vec_string,
                    $thought_data->{branchId},
                    $thought_data->{branchFromThought},
                    $thought_data->{isRevision} ? 1 : 0,
                    $thought_data->{revisesThought}
                );
            }
            else {
                # Handle null embedding case
                $dbh->do(
                    $stmt,
                    undef,
                    $id,
                    $conversation_id,
                    $thought_data->{thoughtNumber},
                    $thought_data->{thought},
                    undef,
                    $thought_data->{branchId},
                    $thought_data->{branchFromThought},
                    $thought_data->{isRevision} ? 1 : 0,
                    $thought_data->{revisesThought}
                );
            }
        }
        else {
            # SQLite case
            $dbh->do(
                "INSERT INTO thoughts (
                    id, conversation_id, thought_number, thought, embedding,
                    branch_id, branch_from_thought, is_revision, revises_thought, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                undef,
                $id, $conversation_id, $thought_data->{thoughtNumber},
                $thought_data->{thought},
                $embedding, $thought_data->{branchId},
                $thought_data->{branchFromThought},
                $thought_data->{isRevision} ? 1 : 0,
                $thought_data->{revisesThought}, $now
            );
        }

        $logger->debug(
"Stored thought #$thought_data->{thoughtNumber} in conversation $conversation_id"
        );

        return $id;
    }

    method get_thought( $conversation_id, $thought_number ) {
        my $sth = $dbh->prepare(
            "SELECT * FROM thoughts
             WHERE conversation_id = ? AND thought_number = ?
             ORDER BY created_at DESC LIMIT 1"
        );
        $sth->execute( $conversation_id, $thought_number );

        return $sth->fetchrow_hashref();
    }

    method get_all_thoughts($conversation_id) {
        my $sth = $dbh->prepare(
            "SELECT * FROM thoughts
             WHERE conversation_id = ?
             ORDER BY thought_number ASC"
        );
        $sth->execute($conversation_id);

        my @thoughts;
        while ( my $row = $sth->fetchrow_hashref() ) {
            push @thoughts, $row;
        }

        return \@thoughts;
    }

    method get_thought_branch( $conversation_id, $branch_id ) {
        my $sth = $dbh->prepare(
            "SELECT * FROM thoughts
             WHERE conversation_id = ? AND branch_id = ?
             ORDER BY thought_number ASC"
        );
        $sth->execute( $conversation_id, $branch_id );

        my @thoughts;
        while ( my $row = $sth->fetchrow_hashref() ) {
            push @thoughts, $row;
        }

        return \@thoughts;
    }

    method get_similar_thoughts( $conversation_id, $thought_text, $limit = 5 ) {
        $logger->debug( "Finding similar thoughts for: "
              . substr( $thought_text, 0, 50 )
              . "..." );

        # Get embedding for the current thought
        my $current_embedding =
          $embedding_service->get_embedding_for_text( $thought_text,
            'document' );

        # Return empty array if we couldn't generate an embedding
        return [] unless $current_embedding;

        if ($is_postgres) {

            # PostgreSQL with pg_vector native similarity search

            # Convert binary embedding to PostgreSQL vector array format
            my @vec_values = unpack( "f*", $current_embedding );
            my $vec_string = '[' . join( ',', @vec_values ) . ']';

            # Use the <=> operator (cosine distance) for semantic similarity
            # 1 - distance gives us similarity (0-1 range)
            my $threshold = $config->similarity_threshold;

            my $sth = $dbh->prepare(
                q{
                SELECT
                    id,
                    thought_number,
                    thought,
                    1 - (embedding <=> $1::vector) AS similarity,
                    branch_id,
                    is_revision,
                    revises_thought
                FROM thoughts
                WHERE
                    conversation_id = $2
                    AND embedding IS NOT NULL
                    AND 1 - (embedding <=> $1::vector) >= $3
                ORDER BY similarity DESC
                LIMIT $4
            }
            );

            # Using bind parameters with PostgreSQL positional syntax
            $sth->execute( $vec_string, $conversation_id, $threshold, $limit );

            my @similar_thoughts;
            while ( my $row = $sth->fetchrow_hashref() ) {
                push @similar_thoughts, $row;
            }

            $logger->debug( "Found "
                  . scalar(@similar_thoughts)
                  . " similar thoughts using pg_vector", );

            return \@similar_thoughts;
        }
        else {
            # SQLite - in-memory similarity calculation

            # Get all thoughts for the conversation
            my $sth = $dbh->prepare(
"SELECT * FROM thoughts WHERE conversation_id = ? ORDER BY thought_number ASC"
            );
            $sth->execute($conversation_id);

            my @all_thoughts;
            while ( my $row = $sth->fetchrow_hashref() ) {
                push @all_thoughts, $row;
            }

            # Calculate similarity scores
            my @scored_thoughts;
            foreach my $thought (@all_thoughts) {
                next unless $thought->{embedding};
                my $similarity =
                  $embedding_service->cosine_similarity( $current_embedding,
                    $thought->{embedding} );

                # Only include thoughts above the threshold
                next unless $similarity >= $config->similarity_threshold;

                push @scored_thoughts,
                  {
                    id              => $thought->{id},
                    thought_number  => $thought->{thought_number},
                    thought         => $thought->{thought},
                    similarity      => $similarity,
                    branch_id       => $thought->{branch_id},
                    is_revision     => $thought->{is_revision},
                    revises_thought => $thought->{revises_thought}
                  };
            }

            # Sort by similarity (highest first)
            my @sorted_thoughts =
              sort { $b->{similarity} <=> $a->{similarity} } @scored_thoughts;

            # Take only the top results
            my @limited_thoughts = splice( @sorted_thoughts, 0, $limit );

            $logger->debug( "Found "
                  . scalar(@limited_thoughts)
                  . " similar thoughts using in-memory comparison" );

            return \@limited_thoughts;
        }
    }

    method disconnect {
        $dbh->disconnect if $dbh;
    }
}

# SequentialThinkingTool - Implements the core sequential thinking capability
class SequentialThinkingTool {
    field $config :param;
    field $logger        = main::get_logger();
    field $thought_store = ThoughtStore->new( config => $config );
    field %active_conversations;

    method handle_request($request) {
        $logger->log("Handling sequential thinking request");

        my $args = $request->{params}{arguments};

        # Validate arguments
        unless ( $args
            && $args->{thought}
            && $args->{thoughtNumber}
            && $args->{totalThoughts} )
        {
            return {
                isError => JSON::PP::true,
                content => [
                    {
                        type => "text",
                        text =>
"Invalid arguments. Required: thought, thoughtNumber, totalThoughts."
                    }
                ]
            };
        }

        # Get or create conversation ID
        my $conversation_id = $active_conversations{ $request->{id} }
          // $thought_store->create_conversation();
        $active_conversations{ $request->{id} } = $conversation_id;

        # Store the current thought
        my $thought_id =
          $thought_store->store_thought( $conversation_id, $args );

        # Find similar previous thoughts if this isn't the first thought
        my $similar_thoughts = [];
        if ( $args->{thoughtNumber} > 1 ) {
            $similar_thoughts =
              $thought_store->get_similar_thoughts( $conversation_id,
                $args->{thought} );
        }

        # Prepare the response
        my $result = "Thought recorded successfully.";

        # Add similar thoughts if any
        if (@$similar_thoughts) {
            $result .= "\n\nSimilar previous thoughts:";
            foreach my $similar (@$similar_thoughts) {
                $result .= sprintf(
                    "\n\nThought #%d (%.2f%% similar):\n%s",
                    $similar->{thought_number},
                    $similar->{similarity} * 100,
                    $similar->{thought}
                );
            }
        }

        return {
            content => [
                {
                    type => "text",
                    text => $result
                }
            ]
        };
    }
}

# MCPServer - Main server class for handling protocol and routing
class MCPServer {
    use JSON::PP qw(decode_json encode_json);
    field $config :param;
    field $logger = main::get_logger();
    field $buffer = '';
    field $sequential_thinking_tool =
      SequentialThinkingTool->new( config => $config );

    method run {
        $logger->info("Starting Semantic Sequential Thinking MCP server...");
        $logger->info("Server ready. Waiting for input...");

        # Simple line-by-line processing loop
        while ( my $line = <STDIN> ) {
            $buffer .= $line;
            $self->process_buffer();
        }

        $logger->info("Server shutting down...");
    }

    method process_buffer {

        # Process line-by-line (each message is on a separate line)
        while ( $buffer =~ s/^(.*)\n// ) {
            my $line = $1;
            next unless $line =~ /\S/;    # Skip empty lines

            $logger->debug("Received message: $line");

            try {
                my $message = decode_json($line);
                $self->handle_message($message);
            }
            catch ($e) {
                $logger->error("Parse error: $e");
                $self->send_error( -32700, "Parse error", undef );
            }
        }
    }

    method handle_message($message) {

        # Validate JSON-RPC version
        if ( !exists $message->{jsonrpc} || $message->{jsonrpc} ne "2.0" ) {
            $self->send_error( -32600, "Invalid Request", $message->{id} );
            return;
        }

        # Handle request
        if ( exists $message->{method} ) {
            $self->handle_request($message);
        }

        # Handle response (not expected in this server)
        elsif ( exists $message->{result} || exists $message->{error} ) {
            $logger->debug("Received response/error message (not handling)");
        }

        # Invalid message
        else {
            $logger->warn("Invalid message format");
            $self->send_error( -32600, "Invalid Request", $message->{id} );
        }
    }

    method handle_request($request) {
        my $method = $request->{method};
        $logger->info("Handling request method: $method");

        if ( $method eq "initialize" ) {
            $self->handle_initialize($request);
        }
        elsif ( $method eq "initialized" ) {
            $logger->info("Received 'initialized' notification");

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
            $logger->info("Received exit notification");

            # No response needed for notifications
            exit(0);
        }
        else {
            $logger->warn("Method not found: $method");
            $self->send_error( -32601, "Method not found: $method",
                $request->{id} );
        }
    }

    method handle_initialize($request) {
        $logger->info("Handling initialize request");

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
                    tools => { listChanged => JSON::PP::true }
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

    method handle_list_tools($request) {
        $logger->info("Handling tools/list request");

        my $response = {
            jsonrpc => "2.0",
            id      => $request->{id},
            result  => {
                tools => [
                    {
                        name        => "sequentialthinking",
                        description =>
"A detailed tool for dynamic and reflective problem-solving through thoughts. This tool helps analyze problems through a flexible thinking process that can adapt and evolve. Each thought can build on, question, or revise previous insights as understanding deepens.",
                        inputSchema => {
                            type     => "object",
                            required => [
                                "thought",       "nextThoughtNeeded",
                                "thoughtNumber", "totalThoughts"
                            ],
                            properties => {
                                thought => {
                                    type        => "string",
                                    description => "Your current thinking step"
                                },
                                nextThoughtNeeded => {
                                    type        => "boolean",
                                    description =>
                                      "Whether another thought step is needed"
                                },
                                thoughtNumber => {
                                    type        => "integer",
                                    description => "Current thought number",
                                    minimum     => 1
                                },
                                totalThoughts => {
                                    type        => "integer",
                                    description =>
                                      "Estimated total thoughts needed",
                                    minimum => 1
                                },
                                isRevision => {
                                    type        => "boolean",
                                    description =>
                                      "Whether this revises previous thinking"
                                },
                                revisesThought => {
                                    type        => "integer",
                                    description =>
                                      "Which thought is being reconsidered",
                                    minimum => 1
                                },
                                branchFromThought => {
                                    type        => "integer",
                                    description =>
                                      "Branching point thought number",
                                    minimum => 1
                                },
                                branchId => {
                                    type        => "string",
                                    description => "Branch identifier"
                                },
                                needsMoreThoughts => {
                                    type        => "boolean",
                                    description => "If more thoughts are needed"
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
        $logger->info("Handling tools/call request");

        my $tool_name = $request->{params}{name}      // '';
        my $tool_args = $request->{params}{arguments} // {};

        $logger->debug("Tool: $tool_name");

        if ( $tool_name eq "sequentialthinking" ) {
            try {
                my $result =
                  $sequential_thinking_tool->handle_request($request);

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => $result
                };

                $self->send_message($response);
            }
            catch ($e) {
                $logger->error(
                    "Error handling sequential thinking request: $e");

                my $response = {
                    jsonrpc => "2.0",
                    id      => $request->{id},
                    result  => {
                        isError => JSON::PP::true,
                        content => [
                            {
                                type => "text",
                                text =>
"Error processing sequential thinking request: $e"
                            }
                        ]
                    }
                };

                $self->send_message($response);
            }
        }
        else {
            $logger->warn("Tool not found: $tool_name");
            $self->send_error( -32601, "Tool not found: $tool_name",
                $request->{id} );
        }
    }

    method handle_shutdown($request) {
        $logger->info("Received shutdown request");

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
        $logger->debug("Sending message: $message_json");
        say $message_json;
    }

    # Send a JSON-RPC error
    method send_error( $code, $message, $id ) {
        $logger->warn("Sending error: $message (code: $code)");

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
    method send_log_notification( $level, $message ) {
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
my $config = SemanticThinkingConfig->new();
my $server = MCPServer->new( config => $config );
$server->run();

__END__

=head1 NAME

semantic-sequential-thinking.pl - MCP server for enhanced sequential thinking with semantic memory

=head1 SYNOPSIS

  ./semantic-sequential-thinking.pl [options]

  Environment Variables:
    DATABASE_DSN        Database connection string (default: dbi:SQLite:dbname=semantic_thinking.db)
    DATABASE_USER       Database username (if needed)
    DATABASE_PASSWORD   Database password (if needed)
    VOYAGE_API_KEY      API key for VoyageAI embeddings
    EMBEDDING_MODEL     Model to use for embeddings (default: voyage-3)
    EMBEDDING_DIMENSIONS Dimensions for the embeddings (default: 1536)
    LOG_LEVEL           Logging level: debug, info, warning, error (default: info)
    LOG_FILE            Optional path to log file
    SIMILARITY_THRESHOLD Minimum similarity score (0-1) to consider thoughts related (default: 0.7)

=head1 DESCRIPTION

This MCP (Model Context Protocol) server implements an enhanced sequential thinking
tool that uses semantic embeddings to improve coherence and memory in reasoning chains.
It can remember similar previous thoughts and provide them as context for future reasoning.

=head1 FEATURES

=over 4

=item * Sequential thinking tool with semantic memory

=item * Persistent storage of thought chains

=item * Semantic similarity between thoughts

=item * Support for thought revisions and branching

=item * Integration with embedding models

=item * Support for both SQLite and PostgreSQL with pg_vector

=back

=head1 DATABASE OPTIONS

This server supports two database backends:

=over 4

=item * SQLite (default) - Simple file-based database, good for development and small deployments

=item * PostgreSQL with pg_vector - High-performance database with native vector operations,
recommended for production deployments with larger thought collections

=back

For PostgreSQL, you'll need to:

=over 4

=item * Install the pg_vector extension in your PostgreSQL database

=item * Set DATABASE_DSN to a PostgreSQL connection string, e.g.:
dbi:Pg:dbname=semantic_thinking;host=localhost;port=5432

=item * Provide DATABASE_USER and DATABASE_PASSWORD if needed

=back

=head1 INTEGRATING WITH CLAUDE DESKTOP

To use this server with Claude for Desktop:

1. Edit the Claude Desktop configuration file:
   ~/Library/Application Support/Claude/claude_desktop_config.json (Mac)
   %AppData%\Claude\claude_desktop_config.json (Windows)

2. Add the server configuration:
   {
     "mcpServers": {
       "semantic-sequential-thinking": {
         "command": "perl",
         "args": [
           "/path/to/semantic-sequential-thinking.pl"
         ],
         "env": {
           "VOYAGE_API_KEY": "your-voyage-api-key",
           "DATABASE_DSN": "dbi:Pg:dbname=semantic_thinking;host=localhost;port=5432",
           "DATABASE_USER": "postgres",
           "DATABASE_PASSWORD": "password"
         }
       }
     }
   }

3. Restart Claude Desktop

=head1 REQUIREMENTS

=over 4

=item * Perl 5.40.0 or higher

=item * DBD::SQLite or DBD::Pg with pg_vector extension

=item * HTTP::Tiny

=item * JSON::PP

=item * Data::UUID

=item * VoyageAI API key for embeddings

=back

=cut
