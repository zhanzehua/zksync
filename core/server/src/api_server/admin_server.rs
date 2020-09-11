// Built-in deps
use std::net::SocketAddr;
use std::thread;

// External uses
use actix_web::dev::ServiceRequest;
use actix_web::{web, App, Error, HttpResponse, HttpServer};
use actix_web_httpauth::extractors::{
    bearer::{BearerAuth, Config},
    AuthenticationError,
};
use actix_web_httpauth::middleware::HttpAuthentication;
use futures::channel::mpsc;
use jsonwebtoken::errors::Error as JwtError;
use jsonwebtoken::{decode, DecodingKey, Validation};
use serde::{Deserialize, Serialize};

// Local uses
use models::config_options::ThreadPanicNotify;
use models::node::{tokens, Address, TokenId};

#[derive(Debug, Serialize, Deserialize)]
struct PayloadAuthToken {
    sub: String, // Subject (whom auth token refers to)
    exp: usize,  // Expiration time (as UTC timestamp)
}

#[derive(Debug)]
struct AppState {
    connection_pool: storage::ConnectionPool,
}

impl AppState {
    fn access_storage(&self) -> actix_web::Result<storage::StorageProcessor> {
        self.connection_pool.access_storage_fragile().map_err(|e| {
            vlog::warn!("Failed to access storage: {}", e);
            actix_web::error::ErrorInternalServerError(e)
        })
    }
}

/// Token that contains information to add to the server
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct AddTokenRequest {
    /// id is used for tx signature and serialization
    /// is optional because when adding the server will assign the next available ID
    pub id: Option<TokenId>,
    /// Contract address of ERC20 token or Address::zero() for "ETH"
    pub address: Address,
    /// Token symbol (e.g. "ETH" or "USDC")
    pub symbol: String,
    /// Token precision (e.g. 18 for "ETH" so "1.0" ETH = 10e18 as U256 number)
    pub decimals: u8,
}

struct AuthTokenValidator<'a> {
    decoding_key: DecodingKey<'a>,
}

impl<'a> AuthTokenValidator<'a> {
    fn new(secret: &'a str) -> Self {
        Self {
            decoding_key: DecodingKey::from_secret(secret.as_ref()),
        }
    }

    /// Validate JsonWebToken
    fn validate_auth_token(&self, token: &str) -> Result<(), JwtError> {
        let token = decode::<PayloadAuthToken>(token, &self.decoding_key, &Validation::default());

        token.map(drop)
    }

    fn validator(
        &self,
        req: ServiceRequest,
        credentials: BearerAuth,
    ) -> Result<ServiceRequest, Error> {
        let config = req
            .app_data::<Config>()
            .map(|data| data.get_ref().clone())
            .unwrap_or_default();

        self.validate_auth_token(credentials.token())
            .map(|_| req)
            .map_err(|_| AuthenticationError::from(config).into())
    }
}

fn add_token(
    data: web::Data<AppState>,
    token_request: web::Json<AddTokenRequest>,
) -> actix_web::Result<HttpResponse> {
    let storage = data.access_storage()?;

    // if id is None then set it to next available ID from server.
    let id = match token_request.id {
        Some(id) => id,
        None => storage.tokens_schema().get_count().map_err(|e| {
            vlog::warn!(
                "failed get number of token from database in progress request: {}",
                e
            );
            actix_web::error::ErrorInternalServerError("storage layer error")
        })? as u16,
    };

    let token = tokens::Token {
        id,
        address: token_request.address,
        symbol: token_request.symbol.clone(),
        decimals: token_request.decimals,
    };

    storage
        .tokens_schema()
        .store_token(token.clone())
        .map_err(|e| {
            vlog::warn!("failed add token to database in progress request: {}", e);
            actix_web::error::ErrorInternalServerError("storage layer error")
        })?;

    Ok(HttpResponse::Ok().json(token))
}

pub fn start_admin_server(
    bind_to: SocketAddr,
    secret_auth: String,
    connection_pool: storage::ConnectionPool,
    panic_notify: mpsc::Sender<bool>,
) {
    thread::Builder::new()
        .name("admin_server".to_string())
        .spawn(move || {
            HttpServer::new(move || {
                let _panic_sentinel = ThreadPanicNotify(panic_notify.clone());
                let secret_auth = secret_auth.clone();

                let app_state = AppState {
                    connection_pool: connection_pool.clone(),
                };

                let auth = HttpAuthentication::bearer(move |req, credentials| {
                    AuthTokenValidator::new(&secret_auth).validator(req, credentials)
                });

                App::new()
                    .wrap(auth)
                    .register_data(web::Data::new(app_state))
                    .route("/tokens", web::post().to(add_token))
            })
            .workers(1)
            .bind(&bind_to)
            .expect("failed to bind")
            .run()
            .expect("failed to run endpoint server");
        })
        .expect("failed to start endpoint server");
}