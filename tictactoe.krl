ruleset tictactoe {
    meta {
        name "Tic-Tac-Toe"
        description
        <<
        A sample ruleset implementing the DidComm Tic-Tac-Toe protocol
        https://github.com/hyperledger/aries-rfcs/blob/main/concepts/0003-protocols/tictactoe/README.md
        >>
        author "Josh Mann"

		shares getGames

        use module io.picolabs.wrangler alias wrangler
		use module io.picolabs.did-o alias didx
    }

    global {

		getGames = function() {
			ent:games
		}

		generate_tictactoe_move = function(their_did, thid, sender_order, me, moves, comment) {
			didx:generate_message({
			  	"type": "did:sov:SLfEi9esrjzybysFxQZbfq;spec/tictactoe/1.0/move",
				"from": didx:didMap(){their_did},
				"to": [their_did],
			  	"thid": thid,
			  	"body": {
					"sender_order": sender_order,
					"me": me,
					"moves": moves,
					"comment": comment
			  	}
			}
			)
		}
	  
		generate_tictactoe_outcome = function(to, thid, seqnum, winner, comment) {
			didx:generate_message({
			  	"type": "did:sov:SLfEi9esrjzybysFxQZbfq;spec/tictactoe/1.0/outcome",
				"from": didx:didMap(){to},
				"to": [to],
			  	"thid": thid,
				"body": {
			  		"winner": winner,
			  		"comment": comment,
					"seqnum": seqnum
				}
			})
		}

		generate_problem_report = function(to, id, message) {
			didx:generate_message({
				"type": "https://didcomm.org/report-problem/1.0/problem-report",
				"from": didx:didMap(){to},
				"to": [to],
				"thid": id,
				"body": {
					"description": message
				}
			})
		}

		get_move_problem = function(id, move) {
			not move.match(re#[XO]:[A-C][1-3]#) =>                 "bad-move" |
			ent:games{id}{"moves"}.any(function(x){ x == move}) => "already-occupied" | 
			                                                       "not-your-turn"
		}
    }

	rule initialize {
		select when wrangler ruleset_installed where event:attrs{"rids"} >< meta:rid
    	pre {
      		route0 = didx:addRoute("did:sov:SLfEi9esrjzybysFxQZbfq;spec/tictactoe/1.0/move", "tictactoe", "receive_move")
      		route1 = didx:addRoute("did:sov:SLfEi9esrjzybysFxQZbfq;spec/tictactoe/1.0/outcome", "tictactoe", "receive_outcome")
      		route2 = didx:addRoute("https://didcomm.org/report-problem/1.0/problem-report", "tictactoe", "receive_problem_report")
    	}
	}

	rule start_game {
		select when tictactoe start_game
		pre {
			to = event:attrs{"to_did"} // DID to start game with
			me = event:attrs{"me"} // X or O
			move = me + ":" + event:attrs{"move"} // [A-C][1-3]
			comment = event:attrs{"comment"}  // Optional
			message = generate_tictactoe_move(to, null, 0, me, [move], comment)
			game = {
				"id": message{"id"},
				"moves": [move],
				"me": me,
				"order": 1,
				"state": "their_move",
				"did": to
			}
		}
		if move.match(re#[XO]:[A-C][1-3]#) then noop()
		fired {
			a = didx:send(to, message)
			ent:games := ent:games.defaultsTo({}).put(game{"id"}, game)
			raise tictactoe event "game_started" attributes event:attrs
		} else {
			raise tictactoe event "report_invalid_move" attributes event:attrs.put("move", move)
		}
	}

    rule send_move {
        select when tictactoe send_move
    	pre {
        	id = event:attrs{"id"}
			move = ent:games{id}{"me"} + ":" + event:attrs{"move"}
			comment = event:attrs{"comment"}
    	}
		// Verify it is my move, the move has not already been made, and it is a valid move
		if  ent:games{id}{"state"} == "my_move" && 
			not ent:games{id}{"moves"}.any(function(x){ x == move }) &&
			move.match(re#[XO]:[A-C][1-3]#) 
		then noop()
		fired {
			raise tictactoe event "move_validated" attributes event:attrs
		} else {
			raise tictactoe event "report_invalid_move" attributes event:attrs
		}
	}

	rule move_validated {
		select when tictactoe move_validated
		pre {
        	id = event:attrs{"id"}
			move = ent:games{id}{"me"} + ":" + event:attrs{"move"}
			comment = event:attrs{"comment"}
			game = ent:games.defaultsTo({}){id}
			updated_game = game.set(["moves"], game{"moves"}.append(move)).set(["order"], game{"order"} + 1).set(["state"], "their-move")
			message = generate_tictactoe_move(game{"did"}, game{"id"}, game{"order"}, game{"me"}, updated_game{"moves"}, comment)
			a = didx:send(game{"did"}, message)
		}
		always {
			ent:games := ent:games.defaultsTo({}).put(game{"id"}, updated_game)
			raise tictactoe event "move_sent" attributes event:attrs
		}
	}

	rule receive_move {
    	select when tictactoe receive_move
		pre {
			message = event:attrs{"message"}
		}
		if (( not ent:games.keys().any(function(x){x == message{"thid"}}))                                                  // Game does not exist
		   || (ent:games{message{"thid"}}{"state"} == "their_move"                                                       	  // OR It is their move
		   && not ent:games{message{"thid"}}{"moves"}.any(function(x){ x == message{"body"}{"moves"}.reverse().head()})))  	  // AND The move is unique
		   && message{"body"}{"moves"}.reverse().head().match(re#[XO]:[A-C][1-3]#) then noop()                              // AND The move is valid
		fired {
			raise tictactoe event "accept_move" attributes event:attrs
		} else {
			raise tictactoe event "send_problem_report" attributes event:attrs
		}
	}

	rule accept_move {
		select when tictactoe accept_move
		pre {
			message = event:attrs{"message"}
			game = (ent:games.defaultsTo({}){message{"thid"}}.set(["moves"], message{"body"}{"moves"}).set(["state"], "my_move") || {
				"id": message{"id"},
				 "moves": message{"body"}{"moves"},
				 "me": message{"body"}{"me"} == "X" => "O" | "X",
				 "order": 1,
				 "state": "my_move",
				 "did": message{"from"}
			})
		}
		always {
			ent:games := ent:games.defaultsTo({}).put(game{"id"}, game)
			raise tictactoe event "move_accepted" attributes event:attrs
		}
	}

  	rule send_outcome {
    	select when tictactoe send_outcome
		pre {
			id = event:attrs{"id"}
			winner = event:attrs{"winner"}
			comment = event:attrs{"comment"}
			seqnum = ent:games{id}{"order"}
			to = ent:games{id}{"did"}
			message = generate_tictactoe_outcome(to, id, seqnum, winner, comment)
			a = didx:send(to, message)
		}
		always {
			raise tictactoe event "outcome_sent" attributes event:attrs
		}
  	}

  	rule receive_outcome {
    	select when tictactoe receive_outcome
		pre {
			message = event:attrs{"message"}.klog("Received outcome: ")
		}
  	}

	rule delete_game {
		select when tictactoe delete_game
		pre {
			id = event:attrs{"id"}
		}
		always {
			ent:games := ent:games.defaultsTo({}).delete(id);
		}
	}

	rule report_invalid_move {
		select when tictactoe report_invalid_move
		pre {
			move = event:attrs{"move"}
			id = event:attrs{"id"}
			problem = get_move_problem(id, move)
		}
		send_directive("say", problem)
		always {
			raise tictactoe event "invalid_move_reported" attributes event:attrs.put("report", problem)
		}
	}

	rule send_problem_report {
		select when tictactoe send_problem_report
		pre {
			message = event:attrs{"message"}
			problem = get_move_problem(message{"thid"}, message{"body"}{"moves"}.reverse().head())
			to = ent:games{message{"thid"}}{"did"}
			report = generate_problem_report(to, message{"thid"}, problem)
			a = didx:send(to, report)
		}
	}

	rule receive_problem_report {
		select when tictactoe receive_problem_report
		pre {
			report = event:attrs{"message"}.klog("Received problem report: ")
		}
	}

}