# Create an authenticated MarkUs API request
markus_request <- function(base_url, api_key, path) {
  httr2::request(paste0(
    sub("/+$", "", base_url),
    "/",
    sub("^/+", "", path)
  )) |>
    httr2::req_headers(
      Authorization = paste("MarkUsAuth", api_key),
      Accept = "application/json"
    )
}

#' Get Visible MarkUs Courses
#'
#' Retrieve courses visible to the authenticated MarkUs user.
#'
#' @param base_url Base URL of the MarkUs instance.
#' @param api_key MarkUs API key.
#'
#' @return Course information returned by the MarkUs API.
#' @export
markus_get_courses <- function(base_url, api_key) {
  markus_request(
    base_url = base_url,
    api_key = api_key,
    path = "api/courses"
  ) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE)
}

#' Get MarkUs Assignments
#'
#' Retrieve assignments available for API submission in a MarkUs course.
#'
#' @param base_url Base URL of the MarkUs instance.
#' @param api_key MarkUs API key.
#' @param course_id MarkUs course ID.
#'
#' @return Assignment information for assignments that allow API submission.
#' @export
markus_get_assignments <- function(base_url, api_key, course_id) {
  assignments <- markus_request(
    base_url = base_url,
    api_key = api_key,
    path = paste0("api/courses/", course_id, "/assignments")
  ) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE)

  assignments[
    !is.na(assignments$api_submit) & assignments$api_submit,
    ,
    drop = FALSE
  ]
}

#' Submit a File to MarkUs
#'
#' Submit a local file to a MarkUs assignment using the MarkUs API.
#'
#' @param base_url Base URL of the MarkUs instance.
#' @param api_key MarkUs API key.
#' @param course_id MarkUs course ID.
#' @param assignment_id MarkUs assignment ID.
#' @param file_path Path to the local file to submit.
#'
#' @return HTTP status code returned by MarkUs.
#' @export
markus_submit_file <- function(base_url, api_key, course_id, assignment_id, file_path) {
  if (!file.exists(file_path)) {
    stop("File does not exist: ", file_path)
  }

  file_content <- readLines(file_path, warn = FALSE) |>
    paste(collapse = "\n")

  response <- markus_request(
    base_url = base_url,
    api_key = api_key,
    path = paste0(
      "api/courses/", course_id,
      "/assignments/", assignment_id,
      "/submit_file"
    )
  ) |>
    httr2::req_body_form(
      filename = basename(file_path),
      mime_type = "text/plain",
      file_content = file_content
    ) |>
    httr2::req_perform()

  httr2::resp_status(response)
}

# Get authentication token from the local RStudio identity service
markus_get_identity_token <- function(
    socket_path = getOption(
      "rmarkus.identity_socket",
      "/run/rmarkus/identity.sock"
    )
) {
  handle <- curl::new_handle()
  
  curl::handle_setopt(
    handle,
    unix_socket_path = socket_path
  )
  
  response <- curl::curl_fetch_memory(
    "http://localhost/",
    handle = handle
  )
  
  if (response$status_code != 200) {
    stop(
      "RStudio identity service returned HTTP ",
      response$status_code
    )
  }
  
  rawToChar(response$content)
}

# Exchange an RStudio identity token for a short-lived MarkUs session token
markus_rstudio_authenticate <- function(
    base_url,
    identity_token
) {
  base_url <- sub("/+$", "", base_url)
  
  url <- paste0(base_url, "/rstudio/authenticate")
  
  response <- httr2::request(url) |>
    httr2::req_method("POST") |>
    httr2::req_headers(
      Authorization = paste("Bearer", identity_token)
    ) |>
    httr2::req_error(is_error = function(resp) FALSE) |>
    httr2::req_perform()
  
  status <- httr2::resp_status(response)
  body <- httr2::resp_body_json(
    response,
    simplifyVector = TRUE
  )
  
  if (status != 200) {
    error_message <- body$message
    
    if (is.null(error_message) || !nzchar(error_message)) {
      error_message <- "RStudio authentication failed."
    }
    
    stop(
      "MarkUs RStudio authentication failed (HTTP ",
      status,
      "): ",
      error_message
    )
  }
  
  if (
    is.null(body$session_token) ||
    !nzchar(body$session_token)
  ) {
    stop("MarkUs did not return a session token.")
  }
  
  body
}


# Create a request authenticated with an RStudio MarkUs session.
markus_rstudio_request <- function(base_url, session_token, path) {
  httr2::request(paste0(
    sub("/+$", "", base_url),
    "/",
    sub("^/+", "", path)
  )) |>
    httr2::req_method("POST") |>
    httr2::req_headers(
      Authorization = paste("MarkUsSession", session_token),
      Accept = "application/json"
    )
}


# Retrieve courses using the authenticated RStudio session.
markus_rstudio_get_courses <- function(base_url, session_token) {
  response <- markus_rstudio_request(
    base_url,
    session_token,
    "rstudio/courses"
  ) |>
    httr2::req_perform()
  
  body <- httr2::resp_body_json(
    response,
    simplifyVector = TRUE
  )
  
  body$courses
}


# Retrieve assignments for the selected course.
markus_rstudio_get_assignments <- function(
    base_url,
    session_token,
    course_id
) {
  response <- markus_rstudio_request(
    base_url,
    session_token,
    "rstudio/assignments"
  ) |>
    httr2::req_body_json(
      list(course_id = as.integer(course_id))
    ) |>
    httr2::req_perform()
  
  body <- httr2::resp_body_json(
    response,
    simplifyVector = TRUE
  )
  
  body$assignments
}


# Submit a local file using the authenticated RStudio session.
markus_rstudio_submit_file <- function(
    base_url,
    session_token,
    course_id,
    assignment_id,
    file_path
) {
  if (!file.exists(file_path)) {
    stop("File does not exist: ", file_path)
  }
  
  file_content <- paste(
    readLines(file_path, warn = FALSE),
    collapse = "\n"
  )
  
  response <- markus_rstudio_request(
    base_url,
    session_token,
    "rstudio/submit"
  ) |>
    httr2::req_body_json(
      list(
        course_id = as.integer(course_id),
        assignment_id = as.integer(assignment_id),
        file_name = basename(file_path),
        file_content = file_content
      )
    ) |>
    httr2::req_perform()
  
  httr2::resp_body_json(
    response,
    simplifyVector = TRUE
  )
}

