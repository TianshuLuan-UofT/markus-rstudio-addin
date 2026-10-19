
#' Submit Active RStudio Document to MarkUs
#'
#' Opens an authenticated submission dialog in RStudio.
#'
#' @return Invisibly returns NULL.
#' @export
markus_submit_addin <- function() {
  
  context <- rstudioapi::getActiveDocumentContext()
  file_path <- context$path
  
  if (!nzchar(file_path) || !file.exists(file_path)) {
    rstudioapi::showDialog(
      "MarkUs Submission",
      "Please save the active document before submitting."
    )
    return(invisible(NULL))
  }
  
  # Server configuration (not shown to students)
  base_url <- getOption("rmarkus.base_url")
  
  if (!is.character(base_url) ||
      length(base_url) != 1L ||
      is.na(base_url) ||
      !nzchar(trimws(base_url))) {
    stop(
      "MarkUs server URL is not configured. ",
      "Please contact your RStudio administrator."
    )
  }
  
  base_url <- sub("/+$", "", trimws(base_url))
  
  ui <- shiny::fluidPage(
    shiny::tags$style(shiny::HTML("
      body { padding: 12px; }
      .form-group { margin-bottom: 18px; }
      .btn-primary { min-width: 110px; }
      .submission-actions {
        display: flex;
        justify-content: flex-end;
        gap: 10px;
      }
    ")),
    
    shiny::h3("Submit to MarkUs"),
    
    shiny::p(
      shiny::strong("File: "),
      basename(file_path)
    ),
    
    shiny::selectInput(
      "course",
      "Course",
      choices = character(0)
    ),
    
    shiny::selectInput(
      "assignment",
      "Assignment",
      choices = character(0)
    ),
    
    shiny::textOutput("status"),
    
    shiny::hr(),
    
    shiny::div(
      class = "submission-actions",
      shiny::actionButton("cancel", "Cancel"),
      shiny::actionButton(
        "submit",
        "Submit",
        class = "btn-primary"
      )
    )
  )
  
  server <- function(input, output, session) {
    
    auth_session <- shiny::reactiveVal(NULL)
    status <- shiny::reactiveVal("Connecting to MarkUs...")
    submitting <- shiny::reactiveVal(FALSE)
    
    output$status <- shiny::renderText(status())
    
    # Authenticate and retrieve courses automatically.
    shiny::observeEvent(TRUE, once = TRUE, {
      
      tryCatch({
        
        identity_token <- markus_get_identity_token()
        
        auth <- markus_rstudio_authenticate(
          base_url = base_url,
          identity_token = identity_token
        )
        
        auth_session(auth)
        
        courses <- markus_rstudio_get_courses(
          base_url = base_url,
          session_token = auth$session_token
        )
        
        if (is.null(courses) || nrow(courses) == 0) {
          status("No available MarkUs courses.")
          return()
        }
        
        shiny::updateSelectInput(
          session,
          "course",
          choices = stats::setNames(
            as.character(courses$id),
            courses$display_name
          )
        )
        
        status("Select a course and assignment.")
        
      }, error = function(e) {
        status(paste(
          "Connection failed:",
          conditionMessage(e)
        ))
      })
    })
    
    # Load assignments whenever the course changes.
    shiny::observeEvent(input$course, {
      
      auth <- auth_session()
      shiny::req(auth, input$course)
      
      tryCatch({
        
        assignments <- markus_rstudio_get_assignments(
          base_url = base_url,
          session_token = auth$session_token,
          course_id = input$course
        )
        
        if (is.null(assignments) || nrow(assignments) == 0) {
          shiny::updateSelectInput(
            session,
            "assignment",
            choices = character(0)
          )
          status("No assignments available for submission.")
          return()
        }
        
        labels <- paste0(
          assignments$short_identifier,
          " - ",
          assignments$description
        )
        
        shiny::updateSelectInput(
          session,
          "assignment",
          choices = stats::setNames(
            as.character(assignments$id),
            labels
          )
        )
        
        status("Ready to submit.")
        
      }, error = function(e) {
        status(paste(
          "Could not load assignments:",
          conditionMessage(e)
        ))
      })
    })
    
    # Submit the selected file.
    shiny::observeEvent(input$submit, {
      
      shiny::req(
        auth_session(),
        input$course,
        input$assignment
      )
      
      if (submitting()) {
        return()
      }
      
      submitting(TRUE)
      on.exit(submitting(FALSE), add = TRUE)
      
      tryCatch({
        
        status("Submitting file...")
        
        auth <- auth_session()
        
        result <- markus_rstudio_submit_file(
          base_url = base_url,
          session_token = auth$session_token,
          course_id = input$course,
          assignment_id = input$assignment,
          file_path = file_path
        )
        
        if (identical(result$status, "success")) {
          status(paste(
            "Successfully submitted",
            basename(file_path)
          ))
          
          shiny::showNotification(
            "File submitted successfully!",
            type = "message",
            duration = 5
          )
          
        } else {
          status("Submission was not successful.")
        }
        
      }, error = function(e) {
        status(paste(
          "Submission failed:",
          conditionMessage(e)
        ))
      })
    })
    
    shiny::observeEvent(input$cancel, {
      shiny::stopApp()
    })
  }
  
  shiny::runGadget(
    shiny::shinyApp(ui, server),
    viewer = shiny::dialogViewer(
      "Submit to MarkUs",
      width = 550,
      height = 500
    )
  )
  
  invisible(NULL)
}
