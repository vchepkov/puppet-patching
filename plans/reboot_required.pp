# @summary Querys a targets operating system to determine if a reboot is required and then reboots the targets that require rebooting.
#
# Patching in different environments comes with various unique requirements, one of those
# is rebooting hosts. Sometimes hosts need to always be reboot, othertimes never rebooted.
#
# To provide this flexibility we created this function that wraps the `reboot` plan with
# a `strategy` that is controllable as a parameter. This provides flexibilty in
# rebooting specific targets in certain ways (by group). Along with the power to expand
# our strategy offerings in the future.
#
# @param [TargetSpec] targets
#   Set of targets to run against.
# @param [Enum['only_required', 'never', 'always']] strategy
#   Determines the reboot strategy for the run.
#
#    - 'only_required' only reboots hosts that require it based on info reported from the OS
#    - 'never' never reboots the hosts
#    - 'always' will reboot the host no matter what
#
# @param [String] message
#   Message displayed to the user prior to the system rebooting
#
# @param [Integer] wait
#   Time in seconds that the plan waits before continuing after a reboot. This is necessary in case one
#   of the groups affects the availability of a previous group.
#   Two use cases here:
#    1. A later group is a hypervisor. In this instance the hypervisor will reboot causing the
#       VMs to go offline and we need to wait for those child VMs to come back up before
#       collecting history metrics.
#    2. A later group is a linux router. In this instance maybe the patching of the linux router
#       affects the reachability of previous hosts.
#
# @param [Integer] disconnect_wait How long (in seconds) to wait before checking whether the server has rebooted. Defaults to 10.
#
# @param [Boolean] noop
#   Flag to determine if this should be a noop operation or not.
#   If this is a noop, no hosts will ever be rebooted, however the "reboot required" information
#   will still be queried and returned.
#
# @return [Struct[{'required' => Array[TargetSpec], 'not_required' => Array[TargetSpec], 'attempted' => Array[TargetSpec], 'resultset' => ResultSet}]]
#
#    - `required` : array of targets whose host OS reported a reboot is required
#    - `not_required` : array of targets whose host OS did not report a reboot being required
#    - `attempted` : array of targets where a reboot was attempted (potentially empty array)
#    - `resultset` : results from the `reboot` plan for the attempted hosts (potentially an empty `ResultSet`)
#
plan patching::reboot_required (
  TargetSpec  $targets,
  Optional[Enum['only_required', 'never', 'always']] $strategy = undef,
  Optional[String] $message = undef,
  Optional[Integer] $wait = undef,
  Optional[Integer] $disconnect_wait = undef,
  Boolean $noop = false,
) {
  $_targets = run_plan('patching::get_targets', $targets)
  $group_vars = $_targets[0].vars
  $_strategy = pick($strategy,
    $group_vars['patching_reboot_strategy'],
  'only_required')
  $_message = pick($message,
    $group_vars['patching_reboot_message'],
  'NOTICE: This system is currently being updated.')
  $_wait = pick($wait,
    $group_vars['patching_reboot_wait'],
  300)
  $_disconnect_wait = pick($disconnect_wait,
    $group_vars['patching_disconnect_wait'],
  10)

  ## Check if reboot required.
  $reboot_results = run_task('patching::reboot_required', $_targets, _catch_errors => true)

  ## Check for errors during reboot check
  $check_filtered = patching::filter_results($reboot_results, 'patching::reboot_required')

  # print out pretty message
  out::message("Reboot strategy: ${_strategy}")
  out::message("Host reboot required status: ('+' reboot required; '-' reboot NOT required)")
  # Extract target names (strings) instead of Target objects to avoid serialization issues
  $targets_reboot_required_names = $reboot_results.filter_set|$res| { $res['reboot_required'] }.targets.map |$t| { $t.name }
  $targets_reboot_not_required_names = $reboot_results.filter_set|$res| { !$res['reboot_required'] }.targets.map |$t| { $t.name }
  $reboot_results.each|$res| {
    $symbol = ($res['reboot_required']) ? { true => '+' , default => '-' }
    out::message(" ${symbol} ${res.target.name}")
  }

  ## Reboot the hosts that require it
  ## skip if we're in noop mode (the reboot plan doesn't support $noop)
  # Extract filtered results immediately to avoid keeping ResultSet with Target objects in scope
  $reboot_filtered = if !$noop {
    case $_strategy {
      'only_required': {
        if !$targets_reboot_required_names.empty() {
          $reboot_temp = run_plan('reboot', $targets_reboot_required_names,
            reconnect_timeout => $_wait,
            disconnect_wait   => $_disconnect_wait,
            message           => $_message,
          _catch_errors     => true)
          patching::filter_results($reboot_temp, 'reboot')
        }
        else {
          patching::filter_results(ResultSet([]), 'reboot')
        }
      }
      'always': {
        $reboot_temp = run_plan('reboot', $targets,
          reconnect_timeout => $_wait,
          disconnect_wait   => $_disconnect_wait,
          message           => $_message,
        _catch_errors     => true)
        patching::filter_results($reboot_temp, 'reboot')
      }
      'never': {
        patching::filter_results(ResultSet([]), 'reboot')
      }
      default: {
        fail_plan("Invalid strategy: ${_strategy}")
      }
    }
  }
  else {
    out::message('Noop specified, skipping all reboots.')
    patching::filter_results(ResultSet([]), 'reboot')
  }

  ## Merge the failed results from both the check and the reboot
  $failed_results = $check_filtered['failed_results'] + $reboot_filtered['failed_results']

  ## Return both sets of failures and successes (reboot not required/successfully rebooted)
  # Convert Target objects to names immediately to avoid serialization issues
  $ok_target_names = ($_targets - $failed_results.keys).map |$target| { $target.name }
  return({
    'ok_targets'     => $ok_target_names,
    'failed_results' => $failed_results,
  })
}
