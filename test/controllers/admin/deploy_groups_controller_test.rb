# frozen_string_literal: true
require_relative '../../test_helper'

SingleCov.covered!

describe Admin::DeployGroupsController do
  let(:deploy_group) { deploy_groups(:pod100) }
  let(:stage) { stages(:test_staging) }

  as_a_deployer do
    unauthorized :get, :index
    unauthorized :get, :show, id: 1
    unauthorized :post, :create
    unauthorized :get, :new
    unauthorized :get, :edit, id: 1
    unauthorized :post, :update, id: 1
    unauthorized :delete, :destroy, id: 1
    unauthorized :get, :deploy_all, id: 1
    unauthorized :post, :deploy_all, id: 1
    unauthorized :post, :create_all_stages, id: 1
  end

  as_a_admin do
    describe "#index" do
      it "renders" do
        get :index
        assert_template :index
        assert_response :success
        assert_select('tbody tr').count.must_equal DeployGroup.count
      end
    end

    describe "#show" do
      it 'renders' do
        get :show, params: {id: deploy_group.id}
        assert_template :show
        assert_response :success
      end
    end

    unauthorized :post, :create
    unauthorized :get, :new
    unauthorized :get, :edit, id: 1
    unauthorized :post, :update, id: 1
    unauthorized :delete, :destroy, id: 1
    unauthorized :get, :deploy_all, id: 1
    unauthorized :post, :deploy_all, id: 1
    unauthorized :post, :create_all_stages, id: 1
  end

  as_a_super_admin do
    describe "#new" do
      it 'renders' do
        get :new
        assert_response :success
      end
    end

    describe '#create' do
      it 'creates a deploy group' do
        assert_difference 'DeployGroup.count', +1 do
          post :create, params: {deploy_group: {name: 'pod666', environment_id: environments(:staging).id}}
          assert_redirected_to admin_deploy_groups_path
        end
      end

      it 'fails with blank name' do
        deploy_group_count = DeployGroup.count
        post :create, params: {deploy_group: {name: nil}}
        assert_template :edit
        DeployGroup.count.must_equal deploy_group_count
      end
    end

    describe '#edit' do
      it "renders" do
        get :edit, params: {id: deploy_group}
        assert_template :edit
      end
    end

    describe '#update' do
      before { request.env["HTTP_REFERER"] = admin_deploy_groups_url }

      it 'saves' do
        post :update, params: {
          deploy_group: {
            name: 'Test Update', environment_id: environments(:production).id
          },
          id: deploy_group.id
        }
        assert_redirected_to admin_deploy_groups_path
        DeployGroup.find(deploy_group.id).name.must_equal 'Test Update'
      end

      it 'fail to update with blank name' do
        post :update, params: {deploy_group: {name: ''}, id: deploy_group}
        assert_template :edit
        deploy_group.reload.name.must_equal 'Pod 100'
      end
    end

    describe '#destroy' do
      it 'succeeds' do
        DeployGroupsStage.delete_all
        delete :destroy, params: {id: deploy_group}
        assert_redirected_to admin_deploy_groups_path
        DeployGroup.where(id: deploy_group.id).must_equal []
      end

      it 'fails for non-existent deploy_group' do
        assert_raises ActiveRecord::RecordNotFound do
          delete :destroy, params: {id: -1}
        end
      end

      it 'fails for used deploy_group and sends user to a page that shows which groups are used' do
        delete :destroy, params: {id: deploy_group}
        assert_redirected_to [:admin, deploy_group]
        assert flash[:error]
        deploy_group.reload
      end
    end

    describe "#deploy_all" do
      it "deploys all stages for this deploy_group" do
        post :deploy_all, params: {id: deploy_group}
        deploy = stage.deploys.order('created_at desc').first.id
        assert_redirected_to "/deploys?ids%5B%5D=#{deploy}"
      end

      it 'ignores template_stages that have not been deployed yet' do
        Deploy.delete_all

        post :deploy_all, params: {id: deploy_group}
        assert_redirected_to "/deploys" # with no ids  present.
      end

      it 'ignores template_stages with only a failed deploy' do
        Job.update_all(status: :failed)

        post :deploy_all, params: {id: deploy_group}
        assert_redirected_to "/deploys" # with no ids  present.
      end

      it 'ignores failed deploy and takes last successful deploy' do
        stage = deploy_group.stages.first

        # verify the test is setup correctly.
        assert stage.last_deploy.failed?
        last_successful_deploy = stage.last_successful_deploy
        assert last_successful_deploy.succeeded?

        post :deploy_all, params: {id: deploy_group}
        assert_equal Deploy.last.reference, last_successful_deploy.reference
      end

      it 'ignores stages with no deploy groups' do
        DeployGroupsStage.delete_all

        post :deploy_all, params: {id: deploy_group}
        assert_redirected_to "/deploys" # with no ids  present.
      end

      it 'ignores stages that include only other deploy groups' do
        env = environments(:staging)
        new_dp = DeployGroup.create!(name: "foo", environment: env)
        DeployGroupsStage.update_all(deploy_group_id: new_dp.id)

        post :deploy_all, params: {id: deploy_group}
        assert_redirected_to "/deploys" # with no ids  present.
      end

      it 'ignores projects with no template for this environment' do
        Stage.update_all(is_template: false)

        post :deploy_all, params: {id: deploy_group}
        assert_redirected_to "/deploys" # with no ids  present.
      end
    end

    describe "#create_all_stages" do
      let(:env) { environments(:staging) }
      let(:deploy_group) { DeployGroup.create!(name: 'Pod 101', environment: env) }
      let(:template_stage) { stages(:test_staging) }

      it 'creates no stages if there are no template_environments' do
        template_stage.update(is_template: false)
        assert_no_difference 'Stage.count' do
          post :create_all_stages, params: {id: deploy_group}
        end
      end

      it 'creates a missing stage for a template_environment' do
        assert_difference 'Stage.count', 1 do
          post :create_all_stages, params: {id: deploy_group}
        end

        refute_empty deploy_group.stages.where(project: template_stage.project)
      end

      it 'adds the new stage to the end of the deploy pipeline' do
        post :create_all_stages, params: {id: deploy_group}

        # the new stage is at the end of the pipeline
        stage = deploy_group.stages.last
        template_stage.next_stage_ids.must_equal([stage.id])
      end
    end

    describe "#create_all_stages_preview" do
      let(:env) { environments(:staging) }
      let(:deploy_group) { DeployGroup.create!(name: 'Pod 101', environment: env) }
      let(:template_stage) { stages(:test_staging) }

      it "finds stages to create" do
        get :create_all_stages_preview, params: {id: deploy_group}

        refute @controller.instance_variable_get(:@missing_stages).empty?
      end

      it "finds precreated stages" do
        # clone the stage
        stage = Stage.build_clone(template_stage)
        stage.deploy_groups << deploy_group
        stage.name = "foo"
        stage.is_template = false
        stage.save!

        get :create_all_stages_preview, params: {id: deploy_group}

        refute @controller.instance_variable_get(:@preexisting_stages).empty?
      end
    end

    describe "#merge_all_stages" do
      describe "without a created stage" do
        it "succeeds with no work to do" do
          post :merge_all_stages, params: {id: deploy_group}
          assert_redirected_to admin_deploy_group_path(deploy_group)
        end
      end

      describe "with a create stage" do
        let(:env) { environments(:staging) }
        let(:deploy_group) { DeployGroup.create!(name: 'Pod 101', environment: env) }
        let(:template_stage) { stages(:test_staging) }

        let :stage do
          Admin::DeployGroupsController.create_all_stages(deploy_group)
          deploy_group.stages.where(project: template_stage.project).first
        end

        before do
          assert template_stage
          assert stage
        end

        it "removes the stage" do
          assert_difference 'Stage.count', -1 do
            post :merge_all_stages, params: {id: deploy_group}
          end
        end

        it "removes the next_stage_id" do
          assert template_stage.reload.next_stage_ids.include?(stage.id)

          post :merge_all_stages, params: {id: deploy_group}

          refute template_stage.reload.next_stage_ids.include?(stage.id)
        end

        it "adds the deploy group to the template stage" do
          refute template_stage.deploy_groups.include?(deploy_group)

          post :merge_all_stages, params: {id: deploy_group}

          assert template_stage.deploy_groups.include?(deploy_group)
        end
      end
    end
  end
end
